import Foundation
import NIOCore
import NIOSSH

/// Failure modes of the pre-flight forwarding probe.
public enum SSHProbeError: Error, Sendable {
    /// No answer within the timeout (auth stuck? server silent?).
    case timeout(host: String, port: Int, seconds: Int)
    /// The server refused the open (e.g. AllowTcpForwarding off, bad auth).
    case refused(host: String, port: Int, detail: String)
    /// Forwarding itself works (localhost opens) but no public target is
    /// reachable: the server's egress is blocked, not its SSH config.
    /// `tried` lists the public "host:port" targets that all failed.
    case egressBlocked(tried: [String])
}

/// Ordered, deduped pre-flight probe targets. No single hardcoded IP is
/// reachable from every network on earth (public DNS is filtered in some
/// countries, offices and captive portals), so the probe races a chain of
/// different-class targets instead of betting on one: the user's own DNS
/// upstream first (the egress they actually need), then three independent
/// public resolvers on :53, then :443 for whitelist-only-80/443 networks.
public enum SSHProbeTargets {
    public static let defaultPublicTargets: [(host: String, port: Int)] = [
        ("8.8.8.8", 53), ("1.1.1.1", 53), ("9.9.9.9", 53), ("1.1.1.1", 443),
    ]
    /// Last-resort target with a different verdict: if this opens while every
    /// public target failed, forwarding is fine and the egress is blocked.
    public static let localhostFallback: (host: String, port: Int) = ("127.0.0.1", 22)
    public static let perTargetTimeoutSeconds = 3

    public static func ordered(userDNS: [String]) -> [(host: String, port: Int)] {
        var out: [(host: String, port: Int)] = []
        var seen = Set<String>()
        func add(host: String, port: Int) {
            let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !h.isEmpty, seen.insert("\(h):\(port)").inserted else { return }
            out.append((host: h, port: port))
        }
        for dns in userDNS { add(host: dns, port: 53) }
        for t in defaultPublicTargets { add(host: t.host, port: t.port) }
        return out
    }
}

/// Pre-flight probe: opens one throwaway direct-tcpip channel and closes it.
/// Success proves (a) SSH auth completed and (b) the server forwards TCP —
/// which also means every later fire-and-forget open will work instead of
/// hanging silently. Blocking with a hard timeout by design: it runs on the
/// startTunnel thread where blocking is already the norm (connect().wait()).
public enum SSHChannelProbe {
    public static func probe(handler: NIOSSHHandler, eventLoop: EventLoop,
                             host: String, port: Int, timeoutSeconds: Int) throws {
        let promise = eventLoop.makePromise(of: Channel.self)
        let type = SSHChannelType.directTCPIP(.init(
            targetHost: host, targetPort: port,
            originatorAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0)))
        // Same eventLoop rule as NIOSSHChannelOpener.open (see above).
        eventLoop.execute {
            handler.createChannel(promise, channelType: type) { childChannel, _ in
                childChannel.close(promise: nil)
                return childChannel.eventLoop.makeSucceededFuture(())
            }
        }
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<Channel, Error>?
        promise.futureResult.whenComplete { result in
            switch result {
            case .success(let channel): outcome = .success(channel)
            case .failure(let error): outcome = .failure(error)
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + .seconds(timeoutSeconds)) == .timedOut {
            throw SSHProbeError.timeout(host: host, port: port, seconds: timeoutSeconds)
        }
        switch outcome {
        case .success: return
        case .failure(let error):
            throw SSHProbeError.refused(host: host, port: port, detail: error.localizedDescription)
        case .none:
            throw SSHProbeError.timeout(host: host, port: port, seconds: timeoutSeconds)
        }
    }
}

/// Production SSHChannelOpener that wraps an NIOSSHHandler and opens
/// direct-tcpip channels for relay flows.
public final class NIOSSHChannelOpener: SSHChannelOpener {
    private let handler: NIOSSHHandler
    private let eventLoop: EventLoop

    public init(handler: NIOSSHHandler, eventLoop: EventLoop) {
        self.handler = handler
        self.eventLoop = eventLoop
    }

    public func open(targetHost: String, targetPort: Int, originatorAddress: SocketAddress,
                     onData: @escaping (Data) -> Void, onClosed: @escaping () -> Void) -> RelayChannel? {
        // Never block the caller (see note below); observe the outcome only.
        let wrapper = SSHRelayChannelWrapper(onData: onData, onClosed: onClosed)
        let type = SSHChannelType.directTCPIP(.init(targetHost: targetHost, targetPort: targetPort,
                                                     originatorAddress: originatorAddress))
        let promise = eventLoop.makePromise(of: Channel.self)
        // MUST run on the event loop: createChannel mutates the handler's
        // pending queue without locking. Calling it from the relay/packet
        // thread silently loses opens (promises never resolve, no error).
        eventLoop.execute { [handler] in
            handler.createChannel(promise, channelType: type) { childChannel, _ in
                childChannel.pipeline.addHandler(wrapper)
            }
        }
        // Observation only — the wrapper is returned immediately so the packet
        // path never stalls. A failed open surfaces here; without this line a
        // server with AllowTcpForwarding=no would fail 100% silently.
        promise.futureResult.whenComplete { result in
            switch result {
            case .success:
                ConsoleLogStore.shared.log(level: .info, tag: "RELAY",
                    message: "direct-tcpip open ok: \(targetHost):\(targetPort)")
            case .failure(let error):
                ConsoleLogStore.shared.log(level: .error, tag: "RELAY",
                    message: "direct-tcpip open FAILED \(targetHost):\(targetPort): \(error.localizedDescription) (check AllowTcpForwarding on server)")
            }
        }
        return wrapper
    }
}
