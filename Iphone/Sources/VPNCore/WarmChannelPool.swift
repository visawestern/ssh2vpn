import Foundation

/// Speculative pre-warming of direct-tcpip channels for "hot" destinations.
///
/// Why this exists: opening a direct-tcpip channel costs one SSH round trip
/// PLUS the server-side TCP handshake before the phone's first byte can move.
/// Browsers open 4-6 parallel connections to the same host per page — after
/// the first flows to a host close, the next ones are predictable. This pool
/// pre-opens a virgin channel so the next SYN to that host skips the cold
/// open entirely.
///
/// Why VIRGIN-only (never reuse a used channel): a direct-tcpip channel IS
/// the server-side TCP connection. Handing a channel that already carried a
/// TLS session to a new flow would deliver the new ClientHello into the old
/// session's crypto state — the server reads garbage and kills it. True
/// "reuse" is impossible for TLS; pre-warming a fresh channel is the safe
/// equivalent. Used channels are closed exactly like today.
///
/// Heating rule: a (dstAddr, dstPort) key arms warming after `warmThreshold`
/// CLEAN closes inside `warmWindow` — clean = the server actually sent bytes
/// (a dead/refusing server must never attract speculative channels).
/// Spawning additionally requires pool slack (`minPoolSlack`), so warming
/// never steals slots under load; parked standbys count toward the SSH pool's
/// inFlight while they live (they are real open channels).
///
/// Hygiene: a standby that receives ANY server bytes while parked is dirty
/// (stragglers from a half-closed session) and is closed instead of handed
/// out; standbys older than `warmTTL` expire; total standbys <= `warmBudget`.
/// A standby whose server side dies is dropped on its close callback.
///
/// Thread safety: all state is lock-guarded. `open()` runs on the relay
/// queue; channel callbacks land on NIO event loops.
public final class WarmChannelPool: RelayChannelFactory, @unchecked Sendable {

    // MARK: - key

    /// Warm identity: destination only. Source ports differ per phone-side
    /// flow, but the server connection they share is per destination.
    public struct Key: Hashable, Sendable {
        public let addr: [UInt8]
        public let port: UInt16
        public let transport: IPTransport

        public init(_ flow: RelayFlow) {
            self.addr = flow.dstAddr
            self.port = flow.dstPort
            self.transport = flow.transport
        }

        public var isV6: Bool { addr.count == 16 }

        public var dotted: String {
            addr.map(String.init).joined(separator: ".") + ":\(port)"
        }
    }

    // MARK: - policy

    public struct Policy: Sendable {
        /// Clean closes inside `warmWindow` that arm warming for a key.
        public var warmThreshold: Int
        /// How far back closes count toward arming.
        public var warmWindow: TimeInterval
        /// Max parked standbys per key.
        public var warmPerKey: Int
        /// Max parked standbys overall.
        public var warmBudget: Int
        /// How long a parked standby stays eligible for handoff.
        public var warmTTL: TimeInterval
        /// Spawn only when the SSH pool has at least this much spare
        /// channel capacity (sum of per-connection headroom).
        public var minPoolSlack: Int

        public init(warmThreshold: Int = 2,
                    warmWindow: TimeInterval = 15,
                    warmPerKey: Int = 1,
                    warmBudget: Int = 4,
                    warmTTL: TimeInterval = 20,
                    minPoolSlack: Int = 3) {
            self.warmThreshold = warmThreshold
            self.warmWindow = warmWindow
            self.warmPerKey = warmPerKey
            self.warmBudget = warmBudget
            self.warmTTL = warmTTL
            self.minPoolSlack = minPoolSlack
        }
    }

    // MARK: - stats

    public struct Stats: Sendable {
        public var spawns = 0
        public var hits = 0
        public var expired = 0
        public var dirtyDrops = 0
        public var deadDrops = 0
        /// Live parked standbys at snapshot time.
        public var standby = 0
    }

    // MARK: - channel

    /// One direct-tcpip channel managed by the pool. Cold opens are handed
    /// immediately (so their close feeds the heat tracker); spawns park
    /// until a matching SYN arrives or they expire.
    public final class Channel: RelayChannel {
        fileprivate enum Mode { case standby, handed, closed }

        fileprivate var real: RelayChannel?
        fileprivate let key: Key
        fileprivate weak var pool: WarmChannelPool?
        fileprivate var mode: Mode = .standby
        /// Live flow's callbacks, bound at handoff.
        fileprivate var flowOnData: ((Data) -> Void)?
        fileprivate var flowOnClosed: (() -> Void)?
        /// Server sent bytes while handed — marks the close as clean.
        fileprivate var sawServerBytes = false
        /// Server sent bytes while parked — never hand this one out.
        fileprivate var dirtyWhileStanding = false
        fileprivate let bornAt: Date

        fileprivate init(key: Key, pool: WarmChannelPool, bornAt: Date) {
            self.key = key
            self.pool = pool
            self.bornAt = bornAt
        }

        public func send(_ data: Data) { real?.send(data) }

        /// Flow-driven close (phone FIN/RST, reopen, idle expire) or pool
        /// eviction — the pool decides which, by mode.
        public func close() { pool?.channelClosed(self) }

        // Wired as the real channel's callbacks at creation:
        fileprivate func receive(_ bytes: Data) { pool?.channelReceived(self, bytes: bytes) }
        fileprivate func remoteClosed() { pool?.channelRemoteClosed(self) }
    }

    // MARK: - state

    private let underlying: RelayChannelFactory
    private let policy: Policy
    /// Spare SSH-pool channel capacity; warming is gated on it.
    /// Production passes pool slack; tests inject a stub.
    private let slack: () -> Int
    private let now: () -> Date
    private let log: (ConsoleLogLevel, String, String) -> Void

    private let lock = NSLock()
    private var standby: [Key: [Channel]] = [:]
    private var recentCloses: [Key: [Date]] = [:]
    private var stats = Stats()

    public init(underlying: RelayChannelFactory,
                policy: Policy = Policy(),
                slack: @escaping () -> Int = { Int.max },
                now: @escaping () -> Date = Date.init,
                log: @escaping (ConsoleLogLevel, String, String) -> Void = { ConsoleLogStore.shared.log(level: $0, tag: $1, message: $2) }) {
        self.underlying = underlying
        self.policy = policy
        self.slack = slack
        self.now = now
        self.log = log
    }

    // MARK: - RelayChannelFactory

    public func open(flow: RelayFlow,
                     onData: @escaping (Data) -> Void,
                     onClosed: @escaping () -> Void) -> RelayChannel {
        let key = Key(flow)
        lock.lock()
        let expired = sweepExpiredLocked()
        var handed: Channel?
        var dirty: [Channel] = []
        if !key.isV6 {
            let taken = takeCleanLocked(key: key)
            handed = taken.channel
            dirty = taken.dropped
            if let ch = handed {
                ch.mode = .handed
                ch.flowOnData = onData
                ch.flowOnClosed = onClosed
                stats.hits += 1
            }
        }
        let left = standbyCountLocked()
        lock.unlock()
        for ch in expired { ch.real?.close() }
        for ch in dirty { ch.real?.close() }
        if let ch = handed {
            log(.success, "WARM", "hit \(key.dotted) — virgin channel handed to new flow (standby left: \(left))")
            return ch
        }
        // Cold open, wrapped so the flow's close feeds the heat tracker.
        let ch = Channel(key: key, pool: self, bornAt: now())
        ch.mode = .handed
        ch.flowOnData = onData
        ch.flowOnClosed = onClosed
        ch.real = underlying.open(flow: flow,
                                  onData: { [weak ch] bytes in ch?.receive(bytes) },
                                  onClosed: { [weak ch] in ch?.remoteClosed() })
        return ch
    }

    /// Live numbers for the 30s journal and tests.
    public func statsSnapshot() -> Stats {
        lock.lock()
        defer { lock.unlock() }
        var s = stats
        s.standby = standbyCountLocked()
        return s
    }

    // MARK: - channel events (lock-guarded)

    /// Flow-driven close. Clean (server-sent-bytes) closes heat the key and
    /// may arm a speculative spawn; the real channel always really closes —
    /// used channels are NEVER re-parked (TLS-poison, see header).
    fileprivate func channelClosed(_ ch: Channel) {
        lock.lock()
        guard ch.mode == .handed else {
            // Pool-evicted standby being torn down, or double close.
            lock.unlock()
            return
        }
        ch.mode = .closed
        let key = ch.key
        let clean = ch.sawServerBytes
        ch.flowOnData = nil
        ch.flowOnClosed = nil
        if clean {
            pruneClosesLocked(key: key)
            recentCloses[key, default: []].append(now())
        }
        lock.unlock()
        ch.real?.close()
        if clean { considerWarming(key: key) }
    }

    fileprivate func channelReceived(_ ch: Channel, bytes: Data) {
        lock.lock()
        switch ch.mode {
        case .handed:
            ch.sawServerBytes = true
            let fwd = ch.flowOnData
            lock.unlock()
            fwd?(bytes)
        case .standby:
            // Stragglers on a parked virgin channel — it can no longer prove
            // a clean server connection. Mark dirty; handoff will drop it.
            ch.dirtyWhileStanding = true
            lock.unlock()
        case .closed:
            lock.unlock()
        }
    }

    fileprivate func channelRemoteClosed(_ ch: Channel) {
        lock.lock()
        switch ch.mode {
        case .standby:
            removeLocked(ch)
            ch.mode = .closed
            stats.deadDrops += 1
            let left = standbyCountLocked()
            lock.unlock()
            log(.warning, "WARM", "standby to \(ch.key.dotted) died remotely — dropped (standby left: \(left))")
        case .handed:
            ch.mode = .closed
            let fwd = ch.flowOnClosed
            ch.flowOnData = nil
            ch.flowOnClosed = nil
            lock.unlock()
            // Same contract as a direct pool channel death: the state
            // machine FINs the phone side.
            fwd?()
        case .closed:
            lock.unlock()
        }
    }

    // MARK: - warming (private)

    /// A clean close just heated `key` — spawn a virgin standby when the
    /// key proves hot AND the pool has slack. Single spawner (only called
    /// from here), so no spawn-dedupe state is needed.
    private func considerWarming(key: Key) {
        lock.lock()
        pruneClosesLocked(key: key)
        guard !key.isV6,
              (recentCloses[key]?.count ?? 0) >= policy.warmThreshold,
              standbyCountLocked() < policy.warmBudget,
              (standby[key]?.count ?? 0) < policy.warmPerKey,
              slack() >= policy.minPoolSlack else {
            lock.unlock()
            return
        }
        // Reset heat: sustained traffic re-arms every `warmThreshold`
        // closes instead of spawning on every single one.
        recentCloses[key] = []
        lock.unlock()
        spawnStandby(key: key)
    }

    private func spawnStandby(key: Key) {
        // Phantom flow: only the destination matters to the pool (target);
        // the originator address is cosmetic.
        let phantom = RelayFlow(srcAddr: [0, 0, 0, 0], srcPort: 0,
                                dstAddr: key.addr, dstPort: key.port,
                                transport: key.transport)
        let ch = Channel(key: key, pool: self, bornAt: now())
        ch.real = underlying.open(flow: phantom,
                                  onData: { [weak ch] bytes in ch?.receive(bytes) },
                                  onClosed: { [weak ch] in ch?.remoteClosed() })
        lock.lock()
        standby[key, default: []].append(ch)
        stats.spawns += 1
        let n = standbyCountLocked()
        lock.unlock()
        log(.info, "WARM", "pre-opened virgin channel to \(key.dotted) (standby: \(n))")
    }

    // MARK: - lock-guarded helpers

    private func standbyCountLocked() -> Int {
        standby.values.reduce(0) { $0 + $1.count }
    }

    /// Closes (returns) standbys older than `warmTTL`.
    private func sweepExpiredLocked() -> [Channel] {
        let t = now()
        var dead: [Channel] = []
        for (key, list) in standby {
            let kept = list.filter { t.timeIntervalSince($0.bornAt) < policy.warmTTL }
            let gone = list.filter { t.timeIntervalSince($0.bornAt) >= policy.warmTTL }
            for ch in gone { ch.mode = .closed }
            stats.expired += gone.count
            if kept.isEmpty {
                standby.removeValue(forKey: key)
            } else {
                standby[key] = kept
            }
            dead.append(contentsOf: gone)
        }
        return dead
    }

    /// Pops the first non-dirty standby for `key`. Dirty ones are returned
    /// for closing — never handed out.
    private func takeCleanLocked(key: Key) -> (channel: Channel?, dropped: [Channel]) {
        guard var list = standby[key], !list.isEmpty else { return (nil, []) }
        var dropped: [Channel] = []
        while !list.isEmpty {
            let ch = list.removeFirst()
            if ch.dirtyWhileStanding {
                ch.mode = .closed
                stats.dirtyDrops += 1
                dropped.append(ch)
                continue
            }
            standby[key] = list.isEmpty ? nil : list
            return (ch, dropped)
        }
        standby[key] = nil
        return (nil, dropped)
    }

    private func removeLocked(_ ch: Channel) {
        guard var list = standby[ch.key] else { return }
        list.removeAll { $0 === ch }
        standby[ch.key] = list.isEmpty ? nil : list
    }

    private func pruneClosesLocked(key: Key) {
        let cutoff = now().addingTimeInterval(-policy.warmWindow)
        if let kept = recentCloses[key]?.filter({ $0 > cutoff }), !kept.isEmpty {
            recentCloses[key] = kept
        } else {
            recentCloses.removeValue(forKey: key)
        }
    }
}
