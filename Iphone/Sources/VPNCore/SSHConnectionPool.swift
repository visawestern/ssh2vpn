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
    /// Default 9 = sshd MaxSessions(10) minus 1 slot of headroom for
    /// server-side session uses (gateway exec for UDP, SFTP) — live flows
    /// can never push the server into tearing the whole SSH connection down.
    /// (The protocol-level keepalive burns no MaxSessions slot, unlike the
    /// old channel-dance ping, but the headroom stays: 9 is conservative.)
    public var channelsPerConnection: Int

    /// Default ceiling 8 (was 4): one live connection in idle, headroom up
    /// to 8 under bursts — dynamic, never a fixed fan-out.
    public init(maxConnections: Int = 8, channelsPerConnection: Int = 9) {
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
    /// for the desired count and the pacer throttles the actual dialing.
    public func desiredConnections(totalInFlight: Int) -> Int {
        let needed = (max(1, totalInFlight) + channelsPerConnection - 1) / channelsPerConnection
        return min(maxConnections, needed)
    }
}

/// Dial throttler for pool growth: caps concurrent SSH handshakes and enforces
/// a minimum gap between dials, so a burst can never storm the server
/// (sshd MaxStartups starts dropping, fail2ban starts banning) while the pool
/// is still allowed to scale. Pure value type, fully unit-testable; callers
/// hold it under the pool lock.
public struct SSHGrowPacer: Sendable {
    private var inFlightDials = 0
    private var lastDialAt: Date?
    private let maxConcurrent: Int
    private let minInterval: TimeInterval

    /// Invalid inputs clamp to the safest usable values: at most one dial at a
    /// time (never zero — growth must stay possible), zero interval (never
    /// negative — back-to-back allowed).
    public init(maxConcurrentDials: Int, minInterval: TimeInterval) {
        self.maxConcurrent = max(1, maxConcurrentDials)
        self.minInterval = max(0, minInterval)
    }

    /// Reserves a dial slot if allowed now. Caller must call `settle()`
    /// exactly once (success or failure) to release the slot.
    public mutating func acquire(at now: Date) -> Bool {
        guard inFlightDials < maxConcurrent else { return false }
        if let lastDialAt, now.timeIntervalSince(lastDialAt) < minInterval { return false }
        inFlightDials += 1
        lastDialAt = now
        return true
    }

    /// Releases one dial slot. Over-settling is a no-op (never underflows).
    public mutating func settle() {
        inFlightDials = max(0, inFlightDials - 1)
    }

    /// Dials currently open (for the 30s journal).
    public var inFlight: Int { inFlightDials }
}

/// Idle shrink: picks which pooled connections may close once they sit idle
/// long enough, keeping a minimum baseline alive. Pure function over
/// (inFlight, idleSince) snapshots — a burst must not sit on a permanent
/// fan-out (it would both stand out on the wire and burn CPU/NAT width), but
/// the single baseline connection must NEVER be evicted (the pool must hold
/// one authenticated connection at all times).
public enum SSHPoolShrink {
    /// Returns indexes of entries eligible for eviction right now.
    /// - inFlight[i]: live channel count on connection i.
    /// - idleSince[i]: when connection i first reached zero channels (nil = never idle / busy).
    /// Rules: only inFlight==0 with a non-nil idleSince older than idleTimeout
    /// qualifies; evict stalest first; never drop below minConnections survivors;
    /// invalid timeout (<=0) is a safe no-op; minConnections clamps to >= 1;
    /// mismatched array lengths operate on the paired prefix (no crashes).
    public static func evictionIndexes(inFlight: [Int],
                                       idleSince: [Date?],
                                       now: Date,
                                       idleTimeout: TimeInterval,
                                       minConnections: Int) -> [Int] {
        guard idleTimeout > 0 else { return [] }
        let keepMin = max(1, minConnections)
        let count = min(inFlight.count, idleSince.count)
        guard count > keepMin else { return [] }
        // Candidates: zero channels, known idle timestamp, older than timeout.
        var candidates: [(index: Int, idleSince: Date)] = []
        for i in 0..<count {
            guard inFlight[i] == 0, let since = idleSince[i], now.timeIntervalSince(since) >= idleTimeout else { continue }
            candidates.append((index: i, idleSince: since))
        }
        // Stalest first, capped so survivors >= keepMin.
        let evictable = min(count - keepMin, candidates.count)
        return candidates
            .sorted { $0.idleSince < $1.idleSince }
            .prefix(evictable)
            .map(\.index)
            .sorted()
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
    /// NIOSSHHandler's Sendable conformance is unavailable (it is a
    /// channel-scoped, non-thread-safe object); the pool itself serializes
    /// access via its lock, so the unchecked conformance is accurate here.
    public struct Link: @unchecked Sendable {
        public let channel: Channel
        public let handler: NIOSSHHandler
        public init(channel: Channel, handler: NIOSSHHandler) {
            self.channel = channel
            self.handler = handler
        }
    }

    /// Async opener for an additional connection. Implemented by the caller
    /// (which owns the SSHTransportFactory + credentials). Crosses from NIO
    /// event loops to the relay queue — hence Sendable.
    public typealias Connector = @Sendable (@escaping (Result<Link, Error>) -> Void) -> Void

    private struct Entry {
        var link: Link
        var inFlight: Int
        /// When this connection first reached zero channels. nil = busy or
        /// never idle. Feeds the idle-shrink selection.
        var idleSince: Date?
        /// Bytes relayed in both directions since the last (re)keying. Feeds
        /// SSHRekeyPolicy (OpenSSH `RekeyLimit 4G`). Wrapping add: at 2^64
        /// the counter would take millennia to matter, but &+ is free.
        var bytesSinceRekey: UInt64 = 0
        /// When the session keys were last (re)negotiated. Feeds the 1h leg
        /// of SSHRekeyPolicy.
        var rekeyedAt: Date = Date()
    }

    private let lock = NSLock()
    private var entries: [Entry]
    /// SSH connects currently opening (a burst may warrant several at once,
    /// throttled by the pacer below).
    private var pendingGrows = 0
    private var nextIndex: Int
    private var closed = false
    /// Consecutive failed heal dials. Drives the exponential backoff so a dead
    /// gateway doesn't get hammered: 1s, 2s, 4s ... capped at 1h (3600s).
    /// Guarded by `lock`.
    private var healAttempts = 0
    private let policy: SSHPoolPolicy
    private let connector: Connector
    private let log: (ConsoleLogLevel, String, String) -> Void
    /// Throttles growth dials (heal dials are NOT paced — they have their own
    /// backoff). Guarded by `lock`.
    private var pacer: SSHGrowPacer
    private let now: () -> Date

    /// Exponential backoff delay (seconds) for heal retry `attempt` (1-based).
    /// Grows 1s, 2s, 4s ... clamped to a hard 3600s (1 hour) ceiling so a dead
    /// server is never DDOSed with connect spam.
    static func healDelay(forAttempt attempt: Int) -> TimeInterval {
        min(3600, pow(2, Double(max(1, attempt) - 1)))
    }

    public init(initial: Link,
                policy: SSHPoolPolicy = SSHPoolPolicy(),
                pacer: SSHGrowPacer = SSHGrowPacer(maxConcurrentDials: 3, minInterval: 0.4),
                connector: @escaping Connector,
                now: @escaping () -> Date = Date.init,
                log: @escaping (ConsoleLogLevel, String, String) -> Void = { ConsoleLogStore.shared.log(level: $0, tag: $1, message: $2) }) {
        self.entries = [Entry(link: initial, inFlight: 0, idleSince: Date())]
        self.nextIndex = 1
        self.policy = policy
        self.pacer = pacer
        self.connector = connector
        self.now = now
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
    /// First dial is immediate; on failure the retry backs off exponentially
    /// (1s → 2s → 4s → ... capped at 1h) instead of hammering dead gateways.
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
        let attempt = healAttempts + 1
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
                    self.entries.append(Entry(link: link, inFlight: 0, idleSince: nil))
                    self.healAttempts = 0
                    let n = self.entries.count
                    self.lock.unlock()
                    self.watch(link: link)
                    self.log(.success, "POOL", "ssh connection restored — pool back to \(n) connection(s); flows will reconnect on it")
                } else {
                    self.lock.unlock()
                    link.channel.close(promise: nil)
                }
            case .failure(let error):
                self.lock.lock()
                self.healAttempts = attempt
                let nextAttempt = self.healAttempts + 1
                let shouldRetry = self.entries.isEmpty && !self.closed
                let delay = Self.healDelay(forAttempt: nextAttempt)
                let retryLabel = delay >= 3600 ? "1h" : "\(Int(delay))s"
                self.lock.unlock()
                self.log(.error, "POOL", "replacement ssh connection failed: \(error.localizedDescription) — retrying in \(retryLabel) (attempt \(nextAttempt))")
                guard shouldRetry else { return }
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    let stillRetry = self.entries.isEmpty && !self.closed
                    self.lock.unlock()
                    if stillRetry { self.heal() }
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

    /// Protocol-level keepalive: one `keepalive@openssh.com` global request
    /// per pooled connection — the exact bytes `ssh -o ServerAliveInterval`
    /// sends. Stock sshd answers SSH_MSG_REQUEST_SUCCESS; the round trip
    /// keeps NAT/sshd idle timers fresh with NO channel open/close dance
    /// (the old dance burned a MaxSessions slot per ping and its OPEN+CLOSE
    /// pair is itself a beacon).
    ///
    /// - Parameter onResponse: invoked once per connection with true on
    ///   REQUEST_SUCCESS, false on FAILURE/send error/closed channel.
    ///   Called on that connection's NIO event loop — callers hop where
    ///   they need. A nil-promise fire-and-forget is NOT used here: the
    ///   caller feeds successes into SSHKeepalivePolicy for dead-peer
    ///   detection.
    public func protocolKeepalive(onResponse: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        let links = entries.map { $0.link }
        lock.unlock()
        for link in links {
            // MUST run on the event loop: sendGlobalRequest mutates the
            // handler's pending queue without locking.
            link.channel.eventLoop.execute {
                guard link.channel.isActive else {
                    onResponse(false)
                    return
                }
                let promise = link.channel.eventLoop.makePromise(of: ByteBuffer?.self)
                promise.futureResult.whenComplete { result in
                    switch result {
                    case .success:
                        onResponse(true)
                    case .failure(let error as NIOSSHError)
                        where error.type == .globalRequestRefused:
                        // The server ANSWERED (with refusal): stock sshd
                        // replies REQUEST_FAILURE to keepalive@openssh.com,
                        // and RFC 4254 §4 mandates FAILURE for unknown
                        // requests. Either reply proves the peer is alive —
                        // real OpenSSH clients treat any answer the same way
                        // (it is silence, not refusal, that means death).
                        onResponse(true)
                    case .failure:
                        onResponse(false)
                    }
                }
                link.handler.sendGlobalRequest(
                    name: SSHCrowdProfile.keepaliveRequestName,
                    payload: link.channel.allocator.buffer(capacity: 0),
                    wantReply: true,
                    promise: promise)
            }
        }
    }

    /// Renegotiates session keys on connections due under `policy` (OpenSSH
    /// `RekeyLimit 4G 1h` schedule). Safe mid-traffic: the state machine
    /// queues channel data during the exchange. Failures only log — the
    /// connection stays up on its old keys and retries next sweep.
    public func rekeyIfNeeded(policy: SSHRekeyPolicy = SSHRekeyPolicy(), now: Date = Date()) {
        lock.lock()
        let due = entries.filter {
            policy.shouldRekey(bytesSinceRekey: $0.bytesSinceRekey,
                               elapsed: now.timeIntervalSince($0.rekeyedAt))
        }.map { $0.link }
        lock.unlock()
        for link in due {
            link.channel.eventLoop.execute { [weak self] in
                // Guard FIRST: rekey() traps (precondition, uncatchable) when
                // called pre-auth or mid-rekey, and pool entries exist from
                // TCP-connect time — authentication finishes asynchronously.
                // Same-turn check+call on the serial loop: nothing interleaves.
                guard link.channel.isActive, link.handler.isReadyForRekey else { return }
                do {
                    try link.handler.rekey()
                    self?.noteRekeyed(link: link)
                    self?.log(.info, "POOL", "rekeyed ssh connection (4G/1h schedule) — session keys rotated")
                } catch {
                    self?.log(.warning, "POOL", "rekey failed (stays on old keys, retries next sweep): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Opens a direct-tcpip channel for `flow` on the least-loaded pooled
    /// connection, growing the pool first if every connection is saturated.
    /// Never blocks: growth completes asynchronously and serves FUTURE opens.
    @discardableResult
    public func open(flow: RelayFlow,
                     onData: @escaping (Data) -> Void,
                     onClosed: @escaping () -> Void) -> RelayChannel {
        let targetHost = flow.dstAddr.map(String.init).joined(separator: ".")
        let targetPort = Int(flow.dstPort)
        return openTo(flow: flow, targetHost: targetHost, targetPort: targetPort,
                      onData: onData, onClosed: onClosed)
    }

    /// Opens a direct-tcpip channel for `flow` toward an explicit remote
    /// target instead of the flow destination. The DNS path needs this:
    /// queries arrive at the tunnel's OWN IP (dstAddr == utun address, e.g.
    /// 10.203.113.2:53), and without the override the server would try to
    /// open a channel to the phone's private tunnel address — every lookup
    /// fails with "direct-tcpip open FAILED <tunnel-ip>:53". TCP flows use
    /// `open(flow:onData:onClosed:)` and the flow destination is used as-is.
    @discardableResult
    public func openTo(flow: RelayFlow,
                       targetHost: String,
                       targetPort: Int,
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
        entries[index].idleSince = nil
        let entry = entries[index]
        let total = entries[index].inFlight
        // Growth: how many connections SHOULD exist for this load, minus
        // those we already have or are already opening. The pacer throttles
        // HOW MANY dials actually launch right now (sshd MaxStartups/fail2ban
        // must never see a burst); denied slots stay unaccounted (pendingGrows
        // unchanged) so a later open can retry them under the lock.
        let totalInFlight = entries.reduce(0) { $0 + $1.inFlight }
        let deficit = policy.desiredConnections(totalInFlight: totalInFlight) - entries.count - pendingGrows
        let nowAt = now()
        var toLaunch = max(0, deficit)
        var launchedNow = 0
        while launchedNow < toLaunch {
            guard pacer.acquire(at: nowAt) else { break }
            launchedNow += 1
            pendingGrows += 1
        }
        lock.unlock()
        for _ in 0..<launchedNow {
            launchGrow()
        }

        let s = flow.srcAddr.map(String.init).joined(separator: ".")
        let d = flow.dstAddr.map(String.init).joined(separator: ".")
        log(.info, "POOL", "flow \(s):\(flow.srcPort) -> \(d):\(flow.dstPort) via ssh#\(index + 1) (\(total) ch on it)")

        let opener = NIOSSHChannelOpener(handler: entry.link.handler, eventLoop: entry.link.channel.eventLoop)
        let originator = (try? SocketAddress(
            ipAddress: flow.srcAddr.map(String.init).joined(separator: "."),
            port: Int(flow.srcPort)))
            ?? (try! SocketAddress(ipAddress: "0.0.0.0", port: 0))
        // Byte accounting for the 4G leg of SSHRekeyPolicy (both directions).
        // The entry INDEX is captured like release() does: shrinkIdle only
        // ever removes higher indexes first, so a live channel's index is
        // stable unless a SIBLING connection drops mid-flow (rare; worst
        // case some bytes land on the wrong entry and a rekey fires early).
        let countedOnData: (Data) -> Void = { [weak self] data in
            self?.addBytes(UInt64(data.count), to: index)
            onData(data)
        }
        guard let raw = opener.open(targetHost: targetHost, targetPort: targetPort,
                                    originatorAddress: originator,
                                    onData: countedOnData,
                                    onClosed: { [weak self] in
                                        self?.release(index: index)
                                        onClosed()
                                    }) else {
            return FailedClosedChannel()
        }
        return ByteCountingRelayChannel(inner: raw) { [weak self] n in
            self?.addBytes(n, to: index)
        }
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
            if entries[index].inFlight == 0, entries[index].idleSince == nil {
                entries[index].idleSince = now()
            }
        }
        lock.unlock()
    }

    /// Attributes relayed bytes to the entry that carried them (see openTo
    /// for the index-stability argument). Hot path: one uncontended lock
    /// hold per chunk (~20ns), never held across user callbacks.
    private func addBytes(_ n: UInt64, to index: Int) {
        guard n > 0 else { return }
        lock.lock()
        if entries.indices.contains(index) {
            entries[index].bytesSinceRekey &+= n
        }
        lock.unlock()
    }

    /// Resets the rekey clock after a successful rotation, matched by parent
    /// channel identity (indexes may have shifted while the rekey was in
    /// flight — identity cannot).
    private func noteRekeyed(link: Link) {
        lock.lock()
        if let i = entries.firstIndex(where: { $0.link.channel === link.channel }) {
            entries[i].bytesSinceRekey = 0
            entries[i].rekeyedAt = now()
        }
        lock.unlock()
    }

    /// Closes idle connections beyond the baseline. Idle = zero live channels
    /// for at least `idleTimeout`; at least `minConnections` always survive.
    /// A burst must not sit on a permanent fan-out (it stands out on the wire
    /// and burns CPU/NAT width) — the pool must shrink back, but never to
    /// zero authenticated connections.
    public func shrinkIdle(idleTimeout: TimeInterval = 60, minConnections: Int = 2) {
        lock.lock()
        let nowAt = now()
        let toEvict = SSHPoolShrink.evictionIndexes(
            inFlight: entries.map(\.inFlight),
            idleSince: entries.map(\.idleSince),
            now: nowAt,
            idleTimeout: idleTimeout,
            minConnections: minConnections)
        guard !closed, !toEvict.isEmpty else { lock.unlock(); return }
        let taken = toEvict.reversed().map { entries.remove(at: $0) }
        lock.unlock()
        for entry in taken {
            entry.link.channel.close(promise: nil)
        }
        log(.success, "POOL", "idle shrink: closed \(taken.count) idle ssh connection(s) — \(entries.count) left (cap \(policy.maxConnections))")
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
            self.pacer.settle()
            self.lock.unlock()
            switch result {
            case .success(let link):
                self.lock.lock()
                if self.closed {
                    self.lock.unlock()
                    link.channel.close(promise: nil)
                    return
                }
                self.entries.append(Entry(link: link, inFlight: 0, idleSince: nil))
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

/// Transparent byte counter for the 4G leg of SSHRekeyPolicy: every chunk
/// sent through the wrapped channel is reported upstream. Identity,
/// backpressure and close semantics are the inner channel's untouched.
private final class ByteCountingRelayChannel: RelayChannel {
    private let inner: RelayChannel
    private let onBytes: (UInt64) -> Void

    init(inner: RelayChannel, onBytes: @escaping (UInt64) -> Void) {
        self.inner = inner
        self.onBytes = onBytes
    }

    func send(_ data: Data) {
        onBytes(UInt64(data.count))
        inner.send(data)
    }

    func close() {
        inner.close()
    }
}
