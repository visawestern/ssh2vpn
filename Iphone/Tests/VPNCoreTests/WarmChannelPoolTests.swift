import XCTest
@testable import VPNCore

/// WarmChannelPool: speculative virgin pre-warm for hot destinations.
/// No NIO here — a fake factory stands in for SSHConnectionPool.
final class WarmChannelPoolTests: XCTestCase {

    // MARK: - fakes

    final class FakeChannel: RelayChannel {
        var sent = [Data]()
        var closed = 0
        var onData: ((Data) -> Void)?
        var onClosed: (() -> Void)?
        func send(_ data: Data) { sent.append(data) }
        func close() { closed += 1 }
    }

    final class FakeFactory: RelayChannelFactory {
        var channels = [FakeChannel]()
        func open(flow: RelayFlow, onData: @escaping (Data) -> Void, onClosed: @escaping () -> Void) -> RelayChannel {
            let ch = FakeChannel()
            ch.onData = onData
            ch.onClosed = onClosed
            channels.append(ch)
            return ch
        }
        var opened: Int { channels.count }
    }

    final class ManualClock {
        var t = Date()
        func now() -> Date { t }
        func advance(_ s: TimeInterval) { t = t.addingTimeInterval(s) }
    }

    // MARK: - helpers

    private func flow(srcPort: UInt16, dst: [UInt8] = [1, 1, 1, 1], dstPort: UInt16 = 443) -> RelayFlow {
        RelayFlow(srcAddr: [10, 0, 0, 2], srcPort: srcPort,
                  dstAddr: dst, dstPort: dstPort, transport: .tcp)
    }

    private func make(factory: FakeFactory = FakeFactory(),
                      clock: ManualClock = ManualClock(),
                      policy: WarmChannelPool.Policy = WarmChannelPool.Policy(),
                      slack: Int = .max) -> WarmChannelPool {
        WarmChannelPool(underlying: factory, policy: policy,
                        slack: { slack }, now: clock.now,
                        log: { _, _, _ in })
    }

    /// Opens a flow on `pool` and returns the handed channel plus the
    /// underlying fake real channel (last one created by the factory).
    @discardableResult
    private func openFlow(_ pool: WarmChannelPool, factory: FakeFactory,
                          srcPort: UInt16,
                          dst: [UInt8] = [1, 1, 1, 1]) -> (handed: RelayChannel, real: FakeChannel) {
        let before = factory.opened
        let ch = pool.open(flow: flow(srcPort: srcPort, dst: dst), onData: { _ in }, onClosed: { })
        XCTAssertEqual(factory.opened, before + 1, "cold open must hit the underlying factory")
        return (ch, factory.channels.last!)
    }

    /// Simulates a full clean flow: cold open, server bytes, phone-FIN close.
    private func cleanFlow(_ pool: WarmChannelPool, factory: FakeFactory,
                           srcPort: UInt16, dst: [UInt8] = [1, 1, 1, 1]) {
        let (handed, real) = openFlow(pool, factory: factory, srcPort: srcPort, dst: dst)
        real.onData?(Data([0x01])) // server answered -> close counts as clean
        handed.close()
        XCTAssertEqual(real.closed, 1, "used channels really close (never re-parked)")
    }

    // MARK: - cold path

    func testColdOpenForwardsSendAndClose() {
        let factory = FakeFactory()
        let pool = make(factory: factory)
        let (handed, real) = openFlow(pool, factory: factory, srcPort: 1000)

        handed.send(Data([0xDE, 0xAD]))
        XCTAssertEqual(real.sent, [Data([0xDE, 0xAD])])

        handed.close()
        XCTAssertEqual(real.closed, 1)
        XCTAssertEqual(factory.opened, 1, "single dirty-less close must not spawn")
        XCTAssertEqual(pool.statsSnapshot().spawns, 0)
    }

    func testSingleCleanCloseDoesNotWarm() {
        let factory = FakeFactory()
        let pool = make(factory: factory)
        cleanFlow(pool, factory: factory, srcPort: 1000)
        XCTAssertEqual(factory.opened, 1)
        XCTAssertEqual(pool.statsSnapshot().standby, 0)
    }

    // MARK: - arming + handoff

    func testTwoCleanClosesSpawnOneStandby() {
        let factory = FakeFactory()
        let pool = make(factory: factory)
        cleanFlow(pool, factory: factory, srcPort: 1000)
        cleanFlow(pool, factory: factory, srcPort: 1001)
        XCTAssertEqual(factory.opened, 3, "2 colds + 1 speculative standby")
        let s = pool.statsSnapshot()
        XCTAssertEqual(s.spawns, 1)
        XCTAssertEqual(s.standby, 1)
    }

    func testWarmHandoffSkipsUnderlyingOpen() {
        let factory = FakeFactory()
        let pool = make(factory: factory)
        cleanFlow(pool, factory: factory, srcPort: 1000)
        cleanFlow(pool, factory: factory, srcPort: 1001)
        XCTAssertEqual(factory.opened, 3)

        var flowData = [Data]()
        let ch = pool.open(flow: flow(srcPort: 1002), onData: { flowData.append($0) }, onClosed: { })
        XCTAssertEqual(factory.opened, 3, "handoff must not touch the underlying factory")
        XCTAssertTrue(ch is WarmChannelPool.Channel)
        XCTAssertEqual(pool.statsSnapshot().hits, 1)
        XCTAssertEqual(pool.statsSnapshot().standby, 0)

        // The handed standby is live: send reaches the pre-opened channel,
        // server bytes reach the new flow.
        ch.send(Data([0x16, 0x03]))
        XCTAssertEqual(factory.channels[2].sent, [Data([0x16, 0x03])])
        factory.channels[2].onData?(Data([0xAA]))
        XCTAssertEqual(flowData, [Data([0xAA])])

        ch.close()
        XCTAssertEqual(factory.channels[2].closed, 1)
        XCTAssertEqual(factory.opened, 3, "handed close without server bytes arms nothing")
    }

    func testHeatResetsAfterSpawn() {
        let factory = FakeFactory()
        var policy = WarmChannelPool.Policy()
        policy.warmPerKey = 2
        let pool = make(factory: factory, policy: policy)
        cleanFlow(pool, factory: factory, srcPort: 1000)
        cleanFlow(pool, factory: factory, srcPort: 1001) // spawn #1 (opened 3)
        XCTAssertEqual(factory.opened, 3)
        // Third flow consumes the standby (handoff, opened stays 3); its
        // clean close reheats 1/2 -> no spawn yet.
        let h3 = pool.open(flow: flow(srcPort: 1002), onData: { _ in }, onClosed: { })
        XCTAssertEqual(factory.opened, 3, "handoff consumes the standby")
        factory.channels[2].onData?(Data([0x01]))
        h3.close()
        XCTAssertEqual(factory.opened, 3)
        XCTAssertEqual(pool.statsSnapshot().spawns, 1)
        // Fourth flow: cold open + clean close -> heat 2/2 -> spawn #2.
        cleanFlow(pool, factory: factory, srcPort: 1003)
        XCTAssertEqual(factory.opened, 5, "1 cold + 1 standby")
        XCTAssertEqual(pool.statsSnapshot().spawns, 2)
    }

    // MARK: - isolation

    func testDifferentDstNotShared() {
        let factory = FakeFactory()
        let pool = make(factory: factory)
        cleanFlow(pool, factory: factory, srcPort: 1000)
        // Second flow to a DIFFERENT host: cold open, must not consume A's standby...
        // (A isn't hot yet with a single close — arm A first via same-dst pair.)
        cleanFlow(pool, factory: factory, srcPort: 1001) // A hot now, standby spawned
        XCTAssertEqual(pool.statsSnapshot().standby, 1)
        let before = factory.opened
        _ = pool.open(flow: flow(srcPort: 2000, dst: [9, 9, 9, 9]), onData: { _ in }, onClosed: { })
        XCTAssertEqual(factory.opened, before + 1, "other dst always cold-opens")
        XCTAssertEqual(pool.statsSnapshot().standby, 1, "A's standby untouched")
    }

    func testV6NeverWarmed() {
        let factory = FakeFactory()
        let pool = make(factory: factory)
        let v6 = [UInt8](repeating: 0x20, count: 16)
        for p: UInt16 in [1000, 1001] {
            let before = factory.opened
            let ch = pool.open(flow: flow(srcPort: p, dst: v6), onData: { _ in }, onClosed: { })
            XCTAssertEqual(factory.opened, before + 1)
            factory.channels.last!.onData?(Data([0x01]))
            ch.close()
        }
        XCTAssertEqual(pool.statsSnapshot().spawns, 0, "v6 keys never arm warming")
    }

    // MARK: - hygiene

    func testDirtyStandbyDroppedNeverHanded() {
        let factory = FakeFactory()
        let pool = make(factory: factory)
        cleanFlow(pool, factory: factory, srcPort: 1000)
        cleanFlow(pool, factory: factory, srcPort: 1001)
        let standbyReal = factory.channels[2]
        standbyReal.onData?(Data([0xFF])) // straggler while parked -> dirty

        let before = factory.opened
        _ = pool.open(flow: flow(srcPort: 1002), onData: { _ in }, onClosed: { })
        XCTAssertEqual(factory.opened, before + 1, "dirty standby must not be handed out")
        XCTAssertEqual(pool.statsSnapshot().dirtyDrops, 1)
        XCTAssertEqual(standbyReal.closed, 1, "dirty standby really closed")
        XCTAssertTrue(factory.channels.last! !== standbyReal, "handed channel is the fresh cold one")
    }

    func testTTLExpiryClosesStandby() {
        let factory = FakeFactory()
        let clock = ManualClock()
        var policy = WarmChannelPool.Policy()
        policy.warmTTL = 10
        let pool = make(factory: factory, clock: clock, policy: policy)
        cleanFlow(pool, factory: factory, srcPort: 1000)
        cleanFlow(pool, factory: factory, srcPort: 1001)
        XCTAssertEqual(pool.statsSnapshot().standby, 1)

        clock.advance(11)
        let standbyReal = factory.channels[2]
        let before = factory.opened
        _ = pool.open(flow: flow(srcPort: 1002), onData: { _ in }, onClosed: { })
        XCTAssertEqual(factory.opened, before + 1, "expired standby must not be handed out")
        XCTAssertEqual(pool.statsSnapshot().expired, 1)
        XCTAssertEqual(standbyReal.closed, 1)
        XCTAssertEqual(pool.statsSnapshot().standby, 0)
    }

    func testDeadStandbyRemovedOnRemoteClose() {
        let factory = FakeFactory()
        let pool = make(factory: factory)
        cleanFlow(pool, factory: factory, srcPort: 1000)
        cleanFlow(pool, factory: factory, srcPort: 1001)
        factory.channels[2].onClosed?() // server side died while parked
        XCTAssertEqual(pool.statsSnapshot().deadDrops, 1)
        XCTAssertEqual(pool.statsSnapshot().standby, 0)

        let before = factory.opened
        _ = pool.open(flow: flow(srcPort: 1002), onData: { _ in }, onClosed: { })
        XCTAssertEqual(factory.opened, before + 1)
    }

    func testNoSlackNoSpawn() {
        let factory = FakeFactory()
        let pool = make(factory: factory, slack: 0)
        cleanFlow(pool, factory: factory, srcPort: 1000)
        cleanFlow(pool, factory: factory, srcPort: 1001)
        XCTAssertEqual(factory.opened, 2, "no pool slack -> no speculative spawn")
        XCTAssertEqual(pool.statsSnapshot().spawns, 0)
    }

    func testBudgetCap() {
        let factory = FakeFactory()
        var policy = WarmChannelPool.Policy()
        policy.warmBudget = 1
        let pool = make(factory: factory, policy: policy)
        cleanFlow(pool, factory: factory, srcPort: 1000)
        cleanFlow(pool, factory: factory, srcPort: 1001) // A hot -> standby (budget full)
        XCTAssertEqual(pool.statsSnapshot().standby, 1)
        // Heat B twice with distinct ports; B must not spawn while budget is full.
        let b: [UInt8] = [8, 8, 8, 8]
        for p: UInt16 in [2000, 2001] {
            let ch = pool.open(flow: flow(srcPort: p, dst: b), onData: { _ in }, onClosed: { })
            factory.channels.last!.onData?(Data([0x01]))
            ch.close()
        }
        XCTAssertEqual(pool.statsSnapshot().spawns, 1, "budget cap holds")
        XCTAssertEqual(pool.statsSnapshot().standby, 1)
    }

    // MARK: - close contract

    func testHandedRemoteCloseForwardsToFlow() {
        let factory = FakeFactory()
        let pool = make(factory: factory)
        var flowClosed = false
        let ch = pool.open(flow: flow(srcPort: 1000), onData: { _ in }, onClosed: { flowClosed = true })
        factory.channels.last!.onClosed?() // server hung up mid-flow
        XCTAssertTrue(flowClosed, "flow must learn the server went away")
        ch.close() // late close after remote death: must not crash or double-release
        XCTAssertEqual(factory.channels.last!.closed, 0, "already-dead real channel is not re-closed by us")
    }

    func testUncleanCloseDoesNotArm() {
        let factory = FakeFactory()
        let pool = make(factory: factory)
        // Two flows that never got a server byte (RST-style / refused server).
        for p: UInt16 in [1000, 1001] {
            let (handed, _) = openFlow(pool, factory: factory, srcPort: p)
            handed.close()
        }
        XCTAssertEqual(factory.opened, 2)
        XCTAssertEqual(pool.statsSnapshot().spawns, 0, "a silent server must not attract warming")
    }
}
