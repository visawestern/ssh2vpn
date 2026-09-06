import Foundation
import NIOCore
import NIOSSH

/// Pure placement decision for one new flow across the pool's connections.
/// Kept separate from NIO types so it is unit-testable.
public struct SSHPoolPolicy: Sendable {
    /// Hard upper bound of parallel SSH connections to the same server.
    public var maxConnections: Int
    /// Soft channel cap per connection. When EVERY pooled connection sits at
    /// or above it, the pool grows (up to maxConnections).
    public var channelsPerConnection: Int

    public init(maxConnections: Int = 4, channelsPerConnection: Int = 4) {
        self.maxConnections = max(1, maxConnections)
        self.channelsPerConnection = max(1, channelsPerConnection)
    }

    /// `inFlight[i]` = live channel count on connection i (never empty).
    /// Returns the index of the least-loaded connection.
    public func plan(inFlight: [Int]) -> Int {
        precondition(!inFlight.isEmpty, "pool must hold at least one connection")
        var best = 0
        for i in inFlight.indices where inFlight[i] < inFlight[best] { best = i }
        return best
    }

    /// How many connections the pool SHOULD have for `totalInFlight` live
    /// channels. Each connection is good for `channelsPerConnection` streams;
    /// a burst browser page (20-40 concurrent streams) immediately warrants
    /// 2-4 parallel connections, and growth can lag creation — so callers ask
    /// for the desired count and open the difference right away (several
    /// grows may fly in parallel).
    public func desiredConnections(totalInFlight: Int) -> Int {
        let needed = (max(1, totalInFlight) + channelsPerConnection - 1) / channelsPerConnection
        return min(maxConnections, needed)
    }
}

/// Pool of parallel SSH connections to the SAME server, each serving many
/// direct-tcpip channels.
///
/// Why: a single SSH TCP connection head-of-line-blocks every flow behind
/// one kernel send queue — a burst of new connections after an app switch
/// (or one stalled segment) stalls all flows. Parallel connections give
/// flows independent send queues, which is the difference between "VPN
/// works" and "VPN feels instant".
///
/// Growth is on demand: the first connection is always used; a new one is
/// opened only when all live connections sit at the channel soft cap
/// (see SSHPoolPolicy). Every grow/ready/failure event is logged (POOL tag)
/// so log dumps show exactly how much parallelism the tunnel spun up.
///
/// Thread safety: all pool state is lock-guarded; open() may be called from
/// the relay queue while growth callbacks land on NIO event loops.
public final class SSHConnectionPool: @unchecked Sendable {

    /// One pooled SSH connection: parent channel + its NIOSSHHandler.
    public struct Link {
        public let channel: Channel
        public let handler: NIOSSHHandler
        public init(channel: Channel, handler: NIOSSHHandler) {
            self.channel = channel
            self.handler = handler
        }
    }

    /// Async opener for an additional connection. Implemented by the caller
    /// (which owns the SSHTransportFactory + credentials).
    public typealias Connector = (@escaping (Result<Link, Error>) -> Void) -> Void

    private struct Entry {
        var link: Link
        var inFlight: Int
    }

    private let lock = NSLock()
    private var entries: [Entry]
    /// SSH connects currently opening (a burst may warrant several at once —
    /// unlike a single grow-in-flight flag, a burst isn't serialized behind
    /// the first connect's latency).
    private var pendingGrows = 0
    private var nextIndex: Int
    private var closed = false
    private let policy: SSHPoolPolicy
    private let connector: Connector
    private let log: (ConsoleLogLevel, String, String) -> Void

    public init(initial: Link,
                policy: SSHPoolPolicy = SSHPoolPolicy(),
                connector: @escaping Connector,
                log: @escaping (ConsoleLogLevel, String, String) -> Void = { ConsoleLogStore.shared.log(level: $0, tag: $1, message: $2) }) {
        self.entries = [Entry(link: initial, inFlight: 0)]
        self.nextIndex = 1
        self.policy = policy
        self.connector = connector
        self.log = log
        watch(link: initial)
    }

    /// Auto-heal: a dropped parent SSH connection (server/NAT timeout) must
    /// not take the tunnel down. The entry is evicted; when the pool runs
    /// empty, a replacement connection is dialed immediately — flows reopen
    /// on it while NetworkExtension keeps the tunnel itself CONNECTED.
    /// This is what keeps the VPN alive in the background for real: no app
    /// process needed for recovery.
    private func watch(link: Link) {
        link.channel.closeFuture.whenComplete { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            if self.closed {
                self.lock.unlock()
                return
            }
            self.entries.removeAll { $0.link.channel === link.channel }
            let remaining = self.entries.count
            let isClosed = self.closed
            self.lock.unlock()
            let dead: String = (try? link.channel.remoteAddress?.description) ?? "?"
            self.log(.warning, "POOL", "ssh connection dropped (\(dead)) — \(remaining) still alive")
            if remaining == 0, !isClosed {
                self.log(.error, "POOL", "last ssh connection lost — auto-healing: dialing a replacement now (tunnel stays up)")
                self.heal()
            }
        }
    }

    /// Re-establishes one connection outside the lock (connector is async).
    private func heal() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        if pendingGrows > 0 {
            // A grow/heal is already dialing — it will refill the pool.
            lock.unlock()
            return
        }
        pendingGrows += 1
        lock.unlock()
        connector { [weak self] result in
            guard let self else { return }
            self.lock.lock()
            self.pendingGrows -= 1
            let isClosed = self.closed
            self.lock.unlock()
            switch result {
            case .success(let link):
                if isClosed {
                    link.channel.close(promise: nil)
                    return
                }
                self.lock.lock()
                if !self.closed {
                    self.entries.append(Entry(link: link, inFlight: 0))
                    let n = self.entries.count
                    self.lock.unlock()
                    self.watch(link: link)
                    self.log(.success, "POOL", "ssh connection restored — pool back to \(n) connection(s); flows will reconnect on it")
                } else {
                    self.lock.unlock()
                    link.channel.close(promise: nil)
                }
            case .failure(let error):
                self.log(.error, "POOL", "replacement ssh connection failed: \(error.localizedDescription) — retrying in 3s")
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    let shouldRetry = self.entries.isEmpty && !self.closed
                    self.lock.unlock()
                    if shouldRetry { self.heal() }
                }
            }
        }
    }

    /// Number of pooled SSH connections right now.
    public var connectionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    /// Per-connection live channel counts (for the 30s journal).
    public func snapshotInFlight() -> [Int] {
        lock.lock(); defer { lock.unlock() }
        return entries.map(\.inFlight)
    }

    /// Keeps every pooled connection visibly active for NAT/sshd idle
    /// timers: opens one throwaway direct-tcpip channel per connection and
    /// closes it immediately. Cheap (one SSH round trip), uses only public
    /// NIOSSH APIs, and runs on each link's own event loop.
    public func keepalivePing() {
        lock.lock()
        let links = entries.map { $0.link }
        lock.unlock()
        for link in links {
            let opener = NIOSSHChannelOpener(handler: link.handler, eventLoop: link.channel.eventLoop)
            opener.open(targetHost: "127.0.0.1", targetPort: 22,
                        originatorAddress: (try? SocketAddress(ipAddress: "127.0.0.1", port: 0)) ?? (try! SocketAddress(ipAddress: "0.0.0.0", port: 0)),
                        onData: { _ in },
                        onClosed: { })
        }
    }

    /// Opens a direct-tcpip channel for `flow` on the least-loaded pooled
    /// connection, growing the pool first if every connection is saturated.
    /// Never blocks: growth completes asynchronously and serves FUTURE opens.
    @discardableResult
    public func open(flow: RelayFlow,
                     onData: @escaping (Data) -> Void,
                     onClosed: @escaping () -> Void) -> RelayChannel {
        lock.lock()
        if closed || entries.isEmpty {
            // Empty while healing: the flow gets a dead channel now and the
            // phone will retransmit its SYN onto the healed pool in ~1s.
            let healing = !closed
            lock.unlock()
            if healing {
                heal()
            }
            return FailedClosedChannel()
        }
        let index = policy.plan(inFlight: entries.map(\.inFlight))
        entries[index].inFlight += 1
        let entry = entries[index]
        let total = entries[index].inFlight
        // Growth: how many connections SHOULD exist for this load, minus
        // those we already have or are already opening. A burst opens the
        // whole deficit at once instead of one connection per RTT. Only the
        // counter is reserved under the lock — the async connects are
        // launched AFTER unlocking (a synchronous test connector must never
        // run into a held lock).
        let totalInFlight = entries.reduce(0) { $0 + $1.inFlight }
        let deficit = policy.desiredConnections(totalInFlight: totalInFlight) - entries.count - pendingGrows
        let toLaunch = max(0, deficit)
        pendingGrows += toLaunch
        lock.unlock()
        for _ in 0..<toLaunch { launchGrow() }

        let s = flow.srcAddr.map(String.init).joined(separator: ".")
        let d = flow.dstAddr.map(String.init).joined(separator: ".")
        log(.info, "POOL", "flow \(s):\(flow.srcPort) -> \(d):\(flow.dstPort) via ssh#\(index + 1) (\(total) ch on it)")

        let opener = NIOSSHChannelOpener(handler: entry.link.handler, eventLoop: entry.link.channel.eventLoop)
        let targetHost = flow.dstAddr.map(String.init).joined(separator: ".")
        let originator = (try? SocketAddress(
            ipAddress: flow.srcAddr.map(String.init).joined(separator: "."),
            port: Int(flow.srcPort)))
            ?? (try! SocketAddress(ipAddress: "0.0.0.0", port: 0))
        return opener.open(targetHost: targetHost, targetPort: Int(flow.dstPort),
                           originatorAddress: originator,
                           onData: onData,
                           onClosed: { [weak self] in
                               self?.release(index: index)
                               onClosed()
                           }) ?? FailedClosedChannel()
    }

    /// Closes every pooled connection (parent channels). Idempotent; late
    /// arrivals after close get a dead channel instead of a zombie flow.
    public func closeAll() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let taken = entries
        entries.removeAll()
        lock.unlock()
        let n = taken.count
        for entry in taken {
            entry.link.channel.close(promise: nil)
        }
        log(.info, "POOL", "closed all \(n) pooled SSH connection(s)")
    }

    // MARK: - private

    private func release(index: Int) {
        lock.lock()
        if entries.indices.contains(index), entries[index].inFlight > 0 {
            entries[index].inFlight -= 1
        }
        lock.unlock()
    }

    /// Establishes one more SSH connection. The slot (pendingGrows) was
    /// already reserved by open(); on failure the reservation is released.
    private func launchGrow() {
        lock.lock()
        let upcoming = entries.count + pendingGrows
        let isClosed = closed
        lock.unlock()
        if isClosed { return }
        log(.info, "POOL", "opening parallel SSH connection #\(upcoming) — \(policy.channelsPerConnection)+ channels each, scaling out for throughput")
        connector { [weak self] result in
            guard let self else { return }
            self.lock.lock()
            self.pendingGrows -= 1
            self.lock.unlock()
            switch result {
            case .success(let link):
                self.lock.lock()
                if self.closed {
                    self.lock.unlock()
                    link.channel.close(promise: nil)
                    return
                }
                self.entries.append(Entry(link: link, inFlight: 0))
                let n = self.entries.count
                self.lock.unlock()
                self.watch(link: link)
                self.log(.success, "POOL", "parallel SSH connection #\(n) ready — \(n)x parallelism to server")
            case .failure(let error):
                self.log(.warning, "POOL", "parallel SSH connection #\(upcoming) failed: \(error.localizedDescription) — staying at current size")
            }
        }
    }
}

/// The pool IS the channel factory for the relay state machine: every new
/// TCP flow lands on the least-loaded pooled SSH connection.
extension SSHConnectionPool: RelayChannelFactory {}

/// Returned when the pool is already torn down — send is a no-op, close is
/// a no-op, matching the old FailedRelayChannel contract.
private final class FailedClosedChannel: RelayChannel {
    func send(_ data: Data) {}
    func close() {}
}
