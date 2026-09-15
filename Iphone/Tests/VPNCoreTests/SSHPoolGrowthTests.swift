import XCTest
@testable import VPNCore

/// Crowd + load discipline: lazy growth to a sane ceiling, paced dials
/// (sshd MaxStartups / fail2ban must never see a burst), idle shrink.
final class SSHPoolGrowthTests: XCTestCase {

    // MARK: - ceiling

    func testDefaultCeilingIsEight() {
        XCTAssertEqual(SSHPoolPolicy().maxConnections, 8,
                       "default ceiling 8: one connection idle, headroom for bursts, no fixed fan-out")
    }

    func testDefaultChannelsPerConnectionUnchanged() {
        XCTAssertEqual(SSHPoolPolicy().channelsPerConnection, 9,
                       "still MaxSessions(10) minus 1 keepalive slot")
    }

    func testInvalidPolicyValuesClamped() {
        XCTAssertEqual(SSHPoolPolicy(maxConnections: 0).maxConnections, 1, "never zero — pool must hold one")
        XCTAssertEqual(SSHPoolPolicy(maxConnections: -3).maxConnections, 1)
        XCTAssertEqual(SSHPoolPolicy(channelsPerConnection: 0).channelsPerConnection, 1)
    }

    // MARK: - pacer

    func testPacerAllowsFirstLaunchImmediately() {
        var pacer = SSHGrowPacer(maxConcurrentDials: 3, minInterval: 10)
        XCTAssertTrue(pacer.acquire(at: Date()))
    }

    func testPacerDeniesWithinInterval() {
        var pacer = SSHGrowPacer(maxConcurrentDials: 3, minInterval: 10)
        let t0 = Date()
        XCTAssertTrue(pacer.acquire(at: t0))
        XCTAssertFalse(pacer.acquire(at: t0.addingTimeInterval(9.9)), "second dial inside the interval must wait")
        XCTAssertTrue(pacer.acquire(at: t0.addingTimeInterval(10)))
    }

    func testPacerCapsConcurrentDials() {
        var pacer = SSHGrowPacer(maxConcurrentDials: 2, minInterval: 0)
        let t0 = Date()
        XCTAssertTrue(pacer.acquire(at: t0))
        XCTAssertTrue(pacer.acquire(at: t0))
        XCTAssertFalse(pacer.acquire(at: t0), "third concurrent dial denied even with zero interval")
        pacer.settle()
        XCTAssertTrue(pacer.acquire(at: t0), "a settled dial frees a slot")
    }

    func testPacerIntervalAndCapCombine() {
        var pacer = SSHGrowPacer(maxConcurrentDials: 2, minInterval: 10)
        let t0 = Date()
        XCTAssertTrue(pacer.acquire(at: t0))
        XCTAssertTrue(pacer.acquire(at: t0.addingTimeInterval(10)))
        pacer.settle()
        XCTAssertFalse(pacer.acquire(at: t0.addingTimeInterval(10)), "interval still applies after settle")
        XCTAssertTrue(pacer.acquire(at: t0.addingTimeInterval(20)))
    }

    func testPacerInvalidInputNeverDeadlocks() {
        var zero = SSHGrowPacer(maxConcurrentDials: 0, minInterval: 5)
        XCTAssertTrue(zero.acquire(at: Date()), "clamped to 1 — pool must always be able to grow by one")
        XCTAssertFalse(zero.acquire(at: Date()))
        var neg = SSHGrowPacer(maxConcurrentDials: -2, minInterval: -5)
        XCTAssertTrue(neg.acquire(at: Date()))
        neg.settle()
        XCTAssertTrue(neg.acquire(at: Date()), "after settle a new dial is allowed; interval clamps to zero")
    }

    func testPacerSettleNeverUnderflows() {
        var pacer = SSHGrowPacer(maxConcurrentDials: 1, minInterval: 0)
        pacer.settle()
        pacer.settle()
        XCTAssertTrue(pacer.acquire(at: Date()), "over-settle must not grant extra slots")
        XCTAssertFalse(pacer.acquire(at: Date()))
    }

    // MARK: - shrink selection (pure)

    func testShrinkEmptyPool() {
        XCTAssertEqual(SSHPoolShrink.evictionIndexes(inFlight: [], idleSince: [], now: Date(),
                                                     idleTimeout: 60, minConnections: 2), [])
    }

    func testShrinkAllBusy() {
        let now = Date()
        XCTAssertEqual(SSHPoolShrink.evictionIndexes(inFlight: [3, 1], idleSince: [nil, nil], now: now,
                                                     idleTimeout: 60, minConnections: 1), [])
    }

    func testShrinkKeepsMinimumEvictingStalestFirst() {
        let now = Date()
        let stale1 = now.addingTimeInterval(-300)
        let stale2 = now.addingTimeInterval(-120)
        let fresh = now.addingTimeInterval(-10)
        let idx = SSHPoolShrink.evictionIndexes(inFlight: [0, 0, 0, 1], idleSince: [stale1, stale2, fresh, nil],
                                                now: now, idleTimeout: 60, minConnections: 2)
        XCTAssertEqual(idx, [0, 1], "evict stalest idle first; fresh idle and busy survive; 2 kept")
    }

    func testShrinkNeverDropsBelowMinimum() {
        let now = Date()
        let old = now.addingTimeInterval(-3600)
        XCTAssertEqual(SSHPoolShrink.evictionIndexes(inFlight: [0], idleSince: [old], now: now,
                                                     idleTimeout: 60, minConnections: 1), [],
                       "last connection never evicted")
        XCTAssertEqual(SSHPoolShrink.evictionIndexes(inFlight: [0, 0], idleSince: [old, old], now: now,
                                                     idleTimeout: 60, minConnections: 5), [],
                       "minimum above count evicts nothing")
    }

    func testShrinkInvalidTimeoutIsNoOp() {
        let now = Date()
        let old = now.addingTimeInterval(-3600)
        XCTAssertEqual(SSHPoolShrink.evictionIndexes(inFlight: [0, 0, 0], idleSince: [old, old, old], now: now,
                                                     idleTimeout: 0, minConnections: 1), [],
                       "zero/negative timeout must not mass-close — safe no-op")
        XCTAssertEqual(SSHPoolShrink.evictionIndexes(inFlight: [0, 0, 0], idleSince: [old, old, old], now: now,
                                                     idleTimeout: -1, minConnections: 1), [])
    }

    func testShrinkInvalidMinimumClampsToOne() {
        let now = Date()
        let old = now.addingTimeInterval(-3600)
        let idx = SSHPoolShrink.evictionIndexes(inFlight: [0, 0], idleSince: [old, old], now: now,
                                                idleTimeout: 60, minConnections: 0)
        XCTAssertEqual(idx.count, 1, "min 0 clamps to 1 — always keep one connection")
    }

    func testShrinkMismatchedLengthsDoNotCrash() {
        let now = Date()
        let old = now.addingTimeInterval(-3600)
        let idx = SSHPoolShrink.evictionIndexes(inFlight: [0, 0, 0], idleSince: [old], now: now,
                                                idleTimeout: 60, minConnections: 1)
        XCTAssertTrue(idx.isEmpty || idx == [0], "paired prefix only, no out-of-bounds, got \(idx)")
    }

    func testShrinkNilIdleSinceMeansNeverIdle() {
        // inFlight==0 but idleSince==nil must not happen; if it does, treat as busy (safe side).
        let now = Date()
        XCTAssertEqual(SSHPoolShrink.evictionIndexes(inFlight: [0, 0], idleSince: [nil, nil], now: now,
                                                     idleTimeout: 60, minConnections: 1), [])
    }
}
