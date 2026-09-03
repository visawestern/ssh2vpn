import Foundation
import NIOCore
import NIOSSH

/// Abstraction over opening a direct-tcpip SSH channel so the factory is
/// testable without a real SSH server. The production implementation wraps
/// an NIOSSHHandler; tests use a mock.
public protocol SSHChannelOpener: AnyObject {
    func open(targetHost: String, targetPort: Int, originatorAddress: SocketAddress,
              onData: @escaping (Data) -> Void, onClosed: @escaping () -> Void) -> RelayChannel?
}

/// Opens direct-tcpip channels for the relay state machine. It maps each
/// flow to a target and wraps the resulting SSH child channel in a
/// SSHRelayChannelWrapper.
public final class SSHRelayChannelFactory: RelayChannelFactory {
    private let opener: SSHChannelOpener

    public init(opener: SSHChannelOpener) {
        self.opener = opener
    }

    public func open(flow: RelayFlow, onData: @escaping (Data) -> Void, onClosed: @escaping () -> Void) -> RelayChannel {
        let targetHost = flow.dstAddr.map(String.init).joined(separator: ".")
        let targetPort = Int(flow.dstPort)
        let originator: SocketAddress = {
            if let addr = try? SocketAddress(ipAddress: flow.srcAddr.map(String.init).joined(separator: "."),
                                             port: Int(flow.srcPort)) {
                return addr
            }
            return try! SocketAddress(ipAddress: "0.0.0.0", port: 0)
        }()

        return opener.open(targetHost: targetHost, targetPort: targetPort,
                           originatorAddress: originator,
                           onData: onData, onClosed: onClosed)
            ?? FailedRelayChannel()
    }
}

/// Placeholder used when the opener returns nil (e.g. channel still opening).
/// It silently drops sends and reports as closed.
private final class FailedRelayChannel: RelayChannel {
    func send(_ data: Data) {}
    func close() {}
}
