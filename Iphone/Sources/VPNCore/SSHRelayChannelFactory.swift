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
        open(flow: flow, targetHost: nil, targetPort: nil, onData: onData, onClosed: onClosed)
    }

    /// Opens a direct-tcpip channel for `flow` toward an explicit remote
    /// target. Used by the DNS path, whose queries arrive at the tunnel's OWN
    /// DNS IP (dstAddr == the utun address, e.g. 10.203.113.2:53) — the real
    /// upstream resolver must be substituted for the flow destination, or the
    /// SSH server tries to reach the phone's private tunnel address and every
    /// lookup dies with "direct-tcpip open FAILED <tunnel-ip>:53".
    public func open(flow: RelayFlow, targetHost: String?, targetPort: Int?,
                     onData: @escaping (Data) -> Void, onClosed: @escaping () -> Void) -> RelayChannel {
        let targetHost = targetHost ?? flow.dstAddr.map(String.init).joined(separator: ".")
        let targetPort = targetPort ?? Int(flow.dstPort)
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
