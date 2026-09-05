import XCTest
import NIOCore
@testable import VPNCore

/// Phase B Round 1: minimal TCP relay state machine — SYN only.
/// One test at a time, watch it fail (RED), then implement (GREEN).
final class TCPRelayTests: XCTestCase {

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
        var channels = [String: FakeChannel]()
        var opened = [String]()
        var capturedOnData: ((Data) -> Void)?
        var capturedOnClosed: (() -> Void)?

        func open(flow: RelayFlow, onData: @escaping (Data) -> Void, onClosed: @escaping () -> Void) -> RelayChannel {
            let key = "\(flow.srcPort)->\(flow.dstAddr.map(String.init).joined(separator: ".")):\(flow.dstPort)"
            let ch = channels[key] ?? FakeChannel()
            channels[key] = ch
            opened.append(key)
            capturedOnData = onData
            capturedOnClosed = onClosed
            ch.onData = onData
            ch.onClosed = onClosed
            return ch
        }
    }

    struct FixedISN: ISNGenerator { func next() -> UInt32 { 5000 } }

    /// Increasing ISNs so tests can distinguish incarnations of one 4-tuple.
    final class SequenceISN: ISNGenerator, @unchecked Sendable {
        var n: UInt32 = 5000
        func next() -> UInt32 { defer { n += 1 }; return n }
    }

    // MARK: - helpers

    private func v4(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> [UInt8] { [a, b, c, d] }

    /// Builds a raw IPv4 SYN packet (no payload, 20-byte TCP header).
    private func synPacket(src: [UInt8], srcPort: UInt16, dst: [UInt8], dstPort: UInt16, seq: UInt32 = 1000) -> [UInt8] {
        var ip = [UInt8](repeating: 0, count: 20)
        ip[0] = 0x45
        let total = 40 // 20 IP + 20 TCP
        ip[2] = UInt8(total >> 8); ip[3] = UInt8(total & 0xFF)
        ip[8] = 64; ip[9] = 6
        ip[12..<16] = src[0..<4]
        ip[16..<20] = dst[0..<4]
        let csum = Checksum.ipHeader(ip)
        ip[10] = UInt8(csum >> 8); ip[11] = UInt8(csum & 0xFF)

        var tcp = [UInt8](repeating: 0, count: 20)
        tcp[0] = UInt8(srcPort >> 8); tcp[1] = UInt8(srcPort & 0xFF)
        tcp[2] = UInt8(dstPort >> 8); tcp[3] = UInt8(dstPort & 0xFF)
        tcp[4] = UInt8(seq >> 24); tcp[5] = UInt8((seq >> 16) & 0xFF)
        tcp[6] = UInt8((seq >> 8) & 0xFF); tcp[7] = UInt8(seq & 0xFF)
        tcp[12] = 0x50 // data offset 5
        tcp[13] = 0x02 // SYN
        tcp[14] = 0xFF; tcp[15] = 0xFF // window
        // TCP checksum = 0 for now (not validated in this round)
        return ip + tcp
    }

    // MARK: - Round 1: SYN (existing)

    func testSynCreatesFlowAndSendsSynAck() throws {
        let factory = FakeFactory()
        var machine = TCPRelayStateMachine(factory: factory, isnGenerator: FixedISN())

        let pkt = synPacket(src: v4(10, 0, 0, 2), srcPort: 1234, dst: v4(1, 1, 1, 1), dstPort: 443)
        let replies = try machine.handle(packet: IPv4Packet(pkt))

        XCTAssertEqual(factory.opened.count, 1, "one channel per SYN")
        XCTAssertEqual(replies.count, 1, "one SYN-ACK reply")
        let flow = IPv4Flow(sourceAddress: 0x0A000002, sourcePort: 1234,
                            destinationAddress: 0x01010101, destinationPort: 443, transport: .tcp)
        XCTAssertEqual(machine.state(for: flow), .synReceived)
    }

    // MARK: - Round 2: ACK completes handshake

    func testAckMovesFlowToEstablished() throws {
        let factory = FakeFactory()
        var machine = TCPRelayStateMachine(factory: factory, isnGenerator: FixedISN())
        let flow = IPv4Flow(sourceAddress: 0x0A000002, sourcePort: 1234,
                            destinationAddress: 0x01010101, destinationPort: 443, transport: .tcp)

        _ = try machine.handle(packet: IPv4Packet(synPacket(src: v4(10, 0, 0, 2), srcPort: 1234, dst: v4(1, 1, 1, 1), dstPort: 443)))
        let replies = try machine.handle(packet: IPv4Packet(ackPacket(flow: flow, seq: 1001, ack: 5001)))

        XCTAssertTrue(replies.isEmpty, "pure ACK produces no reply")
        XCTAssertEqual(machine.state(for: flow), .established)
    }

    // MARK: - Round 3: Data forwarding

    func testDataIsForwardedOverChannel() throws {
        let factory = FakeFactory()
        var machine = TCPRelayStateMachine(factory: factory, isnGenerator: FixedISN())
        let flow = IPv4Flow(sourceAddress: 0x0A000002, sourcePort: 1234,
                            destinationAddress: 0x01010101, destinationPort: 443, transport: .tcp)

        _ = try machine.handle(packet: IPv4Packet(synPacket(src: v4(10, 0, 0, 2), srcPort: 1234, dst: v4(1, 1, 1, 1), dstPort: 443)))
        _ = try machine.handle(packet: IPv4Packet(ackPacket(flow: flow, seq: 1001, ack: 5001)))
        _ = try machine.handle(packet: IPv4Packet(dataPacket(flow: flow, seq: 1001, ack: 5001, payload: [0xDE, 0xAD])))

        let ch = factory.channels.first?.value
        XCTAssertEqual(ch?.sent.count, 1)
        XCTAssertEqual(ch?.sent.first, Data([0xDE, 0xAD]))
    }

    // MARK: - Round 4: FIN closes both sides

    func testFinClosesBothSides() throws {
        let factory = FakeFactory()
        var machine = TCPRelayStateMachine(factory: factory, isnGenerator: FixedISN())
        let flow = IPv4Flow(sourceAddress: 0x0A000002, sourcePort: 1234,
                            destinationAddress: 0x01010101, destinationPort: 443, transport: .tcp)

        _ = try machine.handle(packet: IPv4Packet(synPacket(src: v4(10, 0, 0, 2), srcPort: 1234, dst: v4(1, 1, 1, 1), dstPort: 443)))
        _ = try machine.handle(packet: IPv4Packet(ackPacket(flow: flow, seq: 1001, ack: 5001)))
        let replies = try machine.handle(packet: IPv4Packet(finPacket(flow: flow, seq: 1001, ack: 5001)))

        let ch = factory.channels.first?.value
        XCTAssertEqual(ch?.closed, 1)
        XCTAssertFalse(replies.isEmpty, "FIN gets ACKed back")
    }

    // MARK: - Round 5: RST tears down immediately

    func testRstTearsDownImmediately() throws {
        let factory = FakeFactory()
        var machine = TCPRelayStateMachine(factory: factory, isnGenerator: FixedISN())
        let flow = IPv4Flow(sourceAddress: 0x0A000002, sourcePort: 1234,
                            destinationAddress: 0x01010101, destinationPort: 443, transport: .tcp)

        _ = try machine.handle(packet: IPv4Packet(synPacket(src: v4(10, 0, 0, 2), srcPort: 1234, dst: v4(1, 1, 1, 1), dstPort: 443)))
        _ = try machine.handle(packet: IPv4Packet(ackPacket(flow: flow, seq: 1001, ack: 5001)))
        _ = try machine.handle(packet: IPv4Packet(rstPacket(flow: flow, seq: 2000)))

        XCTAssertEqual(machine.state(for: flow), .closed)
        XCTAssertEqual(factory.channels.first?.value.closed, 1)
    }

    // MARK: - Round 6: Idle timeout

    func testIdleFlowExpires() throws {
        let factory = FakeFactory()
        var machine = TCPRelayStateMachine(factory: factory, isnGenerator: FixedISN(), idleTimeout: 0.01)
        let flow = IPv4Flow(sourceAddress: 0x0A000002, sourcePort: 1234,
                            destinationAddress: 0x01010101, destinationPort: 443, transport: .tcp)

        _ = try machine.handle(packet: IPv4Packet(synPacket(src: v4(10, 0, 0, 2), srcPort: 1234, dst: v4(1, 1, 1, 1), dstPort: 443)))
        XCTAssertEqual(machine.state(for: flow), .synReceived)

        Thread.sleep(forTimeInterval: 0.05)
        let expired = machine.expireIdle()
        XCTAssertGreaterThanOrEqual(expired, 1)
        XCTAssertEqual(machine.state(for: flow), .closed)
    }

    // MARK: - Round 7: Edge cases

    func testRstOnUnknownFlowIsIgnored() throws {
        // RST on unknown flow: nothing to tear down, stay silent (answering
        // RST with RST would loop forever).
        let factory = FakeFactory()
        var machine = TCPRelayStateMachine(factory: factory, isnGenerator: FixedISN())
        let flow = IPv4Flow(sourceAddress: 0x0A000002, sourcePort: 1234,
                            destinationAddress: 0x01010101, destinationPort: 443, transport: .tcp)

        let replies = try machine.handle(packet: IPv4Packet(rstPacket(flow: flow, seq: 2000)))
        XCTAssertTrue(replies.isEmpty)
        XCTAssertNil(machine.state(for: flow))
        XCTAssertEqual(factory.opened.count, 0)
    }

    func testDataOnUnknownFlowGetsRST() throws {
        // Data on a flow we never opened (expired? app restarted?): refuse
        // fast with RST so the phone fails over instead of hanging.
        let factory = FakeFactory()
        var machine = TCPRelayStateMachine(factory: factory, isnGenerator: FixedISN())
        let flow = IPv4Flow(sourceAddress: 0x0A000002, sourcePort: 1234,
                            destinationAddress: 0x01010101, destinationPort: 443, transport: .tcp)

        // PSH, no ACK, seq 100, 5 payload bytes.
        let replies = try machine.handle(packet: IPv4Packet(dataNoAckPacket(flow: flow, seq: 100, payload: [1, 2, 3, 4, 5])))
        XCTAssertEqual(replies.count, 1)
        let seg = try TCPParser.parse(Data(replies[0].dropFirst(20)))
        XCTAssertTrue(seg.flags.contains(.rst))
        XCTAssertEqual(seg.ack, 105, "RST acks past the data per RFC 793 (no ACK was set)")
        XCTAssertNil(machine.state(for: flow), "no state created by refused data")
        XCTAssertEqual(factory.opened.count, 0, "no channel for refused data")
    }

    func testAckOnUnknownFlowGetsRST() throws {
        let factory = FakeFactory()
        var machine = TCPRelayStateMachine(factory: factory, isnGenerator: FixedISN())
        let flow = IPv4Flow(sourceAddress: 0x0A000002, sourcePort: 1234,
                            destinationAddress: 0x01010101, destinationPort: 443, transport: .tcp)

        let replies = try machine.handle(packet: IPv4Packet(ackPacket(flow: flow, seq: 50, ack: 200)))
        XCTAssertEqual(replies.count, 1)
        let seg = try TCPParser.parse(Data(replies[0].dropFirst(20)))
        XCTAssertTrue(seg.flags.contains(.rst))
        XCTAssertEqual(seg.seq, 200, "RST answers with their ack as seq")
    }

    func testSynOnClosedFlowReopens() throws {
        // Port reuse: phone opens a NEW incarnation on a tuple we closed.
        // Must open a fresh channel with a fresh ISN, not stay dead.
        let factory = FakeFactory()
        var machine = TCPRelayStateMachine(factory: factory, isnGenerator: SequenceISN())
        let flow = IPv4Flow(sourceAddress: 0x0A000002, sourcePort: 1234,
                            destinationAddress: 0x01010101, destinationPort: 443, transport: .tcp)

        _ = try machine.handle(packet: IPv4Packet(synPacket(src: v4(10, 0, 0, 2), srcPort: 1234, dst: v4(1, 1, 1, 1), dstPort: 443, seq: 1000)))
        _ = try machine.handle(packet: IPv4Packet(ackPacket(flow: flow, seq: 1001, ack: 5001)))
        _ = try machine.handle(packet: IPv4Packet(rstPacket(flow: flow, seq: 2000)))
        XCTAssertEqual(machine.state(for: flow), .closed)
        XCTAssertEqual(factory.opened.count, 1)

        // New SYN, new incarnation.
        let replies = try machine.handle(packet: IPv4Packet(synPacket(src: v4(10, 0, 0, 2), srcPort: 1234, dst: v4(1, 1, 1, 1), dstPort: 443, seq: 5000)))
        XCTAssertEqual(replies.count, 1)
        let seg = try TCPParser.parse(Data(replies[0].dropFirst(20)))
        XCTAssertEqual(seg.seq, 5001, "fresh ISN for the new incarnation")
        XCTAssertEqual(factory.opened.count, 2, "fresh channel for the new incarnation")
        XCTAssertEqual(machine.state(for: flow), .synReceived)
    }

    func testFullCycleTCP() throws {
        // End-to-end splice contract: every byte in gets acknowledged and
        // every byte back comes out with consistent sequence numbers.
        let factory = FakeFactory()
        var machine = TCPRelayStateMachine(factory: factory, isnGenerator: FixedISN())
        let flow = IPv4Flow(sourceAddress: 0x0A000002, sourcePort: 1234,
                            destinationAddress: 0x01010101, destinationPort: 443, transport: .tcp)
        let rflow = RelayFlow(srcAddr: v4(10, 0, 0, 2), srcPort: 1234,
                              dstAddr: v4(1, 1, 1, 1), dstPort: 443, transport: .tcp)
        // 1. SYN -> SYN-ACK(5000,1001).
        let s1 = try machine.handle(packet: IPv4Packet(synPacket(src: v4(10, 0, 0, 2), srcPort: 1234, dst: v4(1, 1, 1, 1), dstPort: 443, seq: 1000)))
        XCTAssertEqual(s1.count, 1)
        // 2. Early server byte buffers.
        XCTAssertTrue(machine.channelData(Data([0xAA]), for: rflow).isEmpty)
        // 3. ACK completes handshake AND flushes the buffered byte.
        let s3 = try machine.handle(packet: IPv4Packet(ackPacket(flow: flow, seq: 1001, ack: 5001)))
        XCTAssertEqual(s3.count, 1)
        var seg = try TCPParser.parse(Data(s3[0].dropFirst(20)))
        XCTAssertEqual(seg.payload, Data([0xAA]))
        // 4. Phone data goes upstream; an ACK is returned immediately so
        //    the phone's TCP stack doesn't retransmit.
        let s4 = try machine.handle(packet: IPv4Packet(dataPacket(flow: flow, seq: 1001, ack: 5001, payload: [0xDE, 0xAD])))
        XCTAssertEqual(s4.count, 1)
        seg = try TCPParser.parse(Data(s4[0].dropFirst(20)))
        XCTAssertEqual(seg.flags, .ack)
        XCTAssertEqual(seg.seq, 5002)  // localSeq advanced after step 3's server data
        XCTAssertEqual(seg.ack, 1003)
        XCTAssertEqual(seg.payload.count, 0)
        XCTAssertEqual(factory.channels.first?.value.sent, [Data([0xDE, 0xAD])])
        // 5. Server bytes come out with chained seq/ack.
        let s5 = machine.channelData(Data([0xBB]), for: rflow)
        XCTAssertEqual(s5.count, 1)
        seg = try TCPParser.parse(Data(s5[0].dropFirst(20)))
        XCTAssertEqual(seg.seq, 5002)
        XCTAssertEqual(seg.ack, 1003)
        XCTAssertEqual(seg.payload, Data([0xBB]))
        // 6. Server close -> FIN to phone.
        let s6 = machine.channelClosed(flow: rflow)
        XCTAssertEqual(s6.count, 1)
        seg = try TCPParser.parse(Data(s6[0].dropFirst(20)))
        XCTAssertTrue(seg.flags.contains(.fin))
    }

    func testSeqConsistencyUnderInterleave() throws {
        let factory = FakeFactory()
        var machine = TCPRelayStateMachine(factory: factory, isnGenerator: FixedISN())
        let flow = IPv4Flow(sourceAddress: 0x0A000002, sourcePort: 1234,
                            destinationAddress: 0x01010101, destinationPort: 443, transport: .tcp)
        let rflow = RelayFlow(srcAddr: v4(10, 0, 0, 2), srcPort: 1234,
                              dstAddr: v4(1, 1, 1, 1), dstPort: 443, transport: .tcp)
        _ = try machine.handle(packet: IPv4Packet(synPacket(src: v4(10, 0, 0, 2), srcPort: 1234, dst: v4(1, 1, 1, 1), dstPort: 443, seq: 1000)))
        _ = try machine.handle(packet: IPv4Packet(ackPacket(flow: flow, seq: 1001, ack: 5001)))
        // Phone 10 bytes.
        _ = try machine.handle(packet: IPv4Packet(dataPacket(flow: flow, seq: 1001, ack: 5001, payload: [UInt8](repeating: 0xA0, count: 10))))
        // Server 5 bytes: our seq 5001, ack peer 1011.
        var r = machine.channelData(Data([UInt8](repeating: 0xB0, count: 5)), for: rflow)
        var seg = try TCPParser.parse(Data(r[0].dropFirst(20)))
        XCTAssertEqual(seg.seq, 5001)
        XCTAssertEqual(seg.ack, 1011)
        // Phone 3 more bytes (seq 1011).
        _ = try machine.handle(packet: IPv4Packet(dataPacket(flow: flow, seq: 1011, ack: 5006, payload: [UInt8](repeating: 0xC0, count: 3))))
        // Server 7 bytes: our seq 5006, ack peer 1014.
        r = machine.channelData(Data([UInt8](repeating: 0xD0, count: 7)), for: rflow)
        seg = try TCPParser.parse(Data(r[0].dropFirst(20)))
        XCTAssertEqual(seg.seq, 5006)
        XCTAssertEqual(seg.ack, 1014)
        // Byte counters agree with the wire.
        let stats = machine.flowStats().first { $0.flow == rflow }
        XCTAssertEqual(stats?.upBytes, 13)
        XCTAssertEqual(stats?.downBytes, 12)
    }

    func testGarbageInputsNeverTrap() throws {
        let factory = FakeFactory()
        var machine = TCPRelayStateMachine(factory: factory, isnGenerator: FixedISN())
        // Empty / truncated / wrong version: throw cleanly, never trap.
        XCTAssertThrowsError(try machine.handle(packet: IPv4Packet([])))
        XCTAssertThrowsError(try machine.handle(packet: IPv4Packet([0x45])))
        // UDP (non-TCP) is ignored, not an error.
        var udp = [UInt8](repeating: 0, count: 28)
        udp[0] = 0x45
        udp[2] = 0; udp[3] = 28
        udp[8] = 64; udp[9] = 17
        udp[12] = 10; udp[15] = 2; udp[16] = 8; udp[19] = 8
        XCTAssertEqual(try machine.handle(packet: IPv4Packet(udp)).count, 0)
        // Declared length beyond buffer: throws cleanly, never trapped.
        var short = [UInt8](repeating: 0, count: 20)
        short[0] = 0x45; short[2] = 0; short[3] = 100; short[8] = 64; short[9] = 6
        XCTAssertThrowsError(try machine.handle(packet: IPv4Packet(short)))
    }

    func testDuplicateSynResendsSynAck() throws {
        let factory = FakeFactory()
        var machine = TCPRelayStateMachine(factory: factory, isnGenerator: FixedISN())

        let pkt = synPacket(src: v4(10, 0, 0, 2), srcPort: 1234, dst: v4(1, 1, 1, 1), dstPort: 443)
        let r1 = try machine.handle(packet: IPv4Packet(pkt))
        let r2 = try machine.handle(packet: IPv4Packet(pkt))

        XCTAssertEqual(factory.opened.count, 1, "still one channel")
        XCTAssertEqual(r1.count, 1)
        XCTAssertEqual(r2.count, 1, "duplicate SYN resends SYN-ACK")
    }

    // MARK: - Round 9: flow census for status reporting

    func testFlowCountTracksLiveFlows() throws {
        let factory = FakeFactory()
        var machine = TCPRelayStateMachine(factory: factory, isnGenerator: FixedISN())
        XCTAssertEqual(machine.flowCount, 0)

        _ = try machine.handle(packet: IPv4Packet(synPacket(src: v4(10, 0, 0, 2), srcPort: 1234, dst: v4(1, 1, 1, 1), dstPort: 443)))
        XCTAssertEqual(machine.flowCount, 1)

        _ = try machine.handle(packet: IPv4Packet(synPacket(src: v4(10, 0, 0, 2), srcPort: 4321, dst: v4(1, 1, 1, 1), dstPort: 443)))
        XCTAssertEqual(machine.flowCount, 2)
    }

    // MARK: - Round 10: server-to-phone splice (channel data -> utun packets)

    func testChannelDataBuildsReplyPacket() throws {
        let factory = FakeFactory()
        var machine = TCPRelayStateMachine(factory: factory, isnGenerator: FixedISN())
        let flow = IPv4Flow(sourceAddress: 0x0A000002, sourcePort: 1234,
                            destinationAddress: 0x01010101, destinationPort: 443, transport: .tcp)
        _ = try machine.handle(packet: IPv4Packet(synPacket(src: v4(10, 0, 0, 2), srcPort: 1234, dst: v4(1, 1, 1, 1), dstPort: 443)))
        _ = try machine.handle(packet: IPv4Packet(ackPacket(flow: flow, seq: 1001, ack: 5001)))

        let rflow = RelayFlow(srcAddr: v4(10, 0, 0, 2), srcPort: 1234,
                              dstAddr: v4(1, 1, 1, 1), dstPort: 443, transport: .tcp)
        let pkts = machine.channelData(Data([0xAA]), for: rflow)
        XCTAssertEqual(pkts.count, 1)
        let seg = try TCPParser.parse(Data(pkts[0].dropFirst(20)))
        XCTAssertEqual(seg.seq, 5001, "first server byte uses ISN+1")
        XCTAssertEqual(seg.ack, 1001)
        XCTAssertEqual(seg.payload, Data([0xAA]))
        XCTAssertTrue(seg.flags.contains(.ack))
    }

    func testChannelDataAdvancesSequence() throws {
        let factory = FakeFactory()
        var machine = TCPRelayStateMachine(factory: factory, isnGenerator: FixedISN())
        let flow = IPv4Flow(sourceAddress: 0x0A000002, sourcePort: 1234,
                            destinationAddress: 0x01010101, destinationPort: 443, transport: .tcp)
        _ = try machine.handle(packet: IPv4Packet(synPacket(src: v4(10, 0, 0, 2), srcPort: 1234, dst: v4(1, 1, 1, 1), dstPort: 443)))
        _ = try machine.handle(packet: IPv4Packet(ackPacket(flow: flow, seq: 1001, ack: 5001)))
        let rflow = RelayFlow(srcAddr: v4(10, 0, 0, 2), srcPort: 1234,
                              dstAddr: v4(1, 1, 1, 1), dstPort: 443, transport: .tcp)
        _ = machine.channelData(Data([0xAA]), for: rflow)
        let pkts = machine.channelData(Data([0xBB, 0xCC]), for: rflow)
        let seg = try TCPParser.parse(Data(pkts[0].dropFirst(20)))
        XCTAssertEqual(seg.seq, 5002)
        XCTAssertEqual(seg.payload, Data([0xBB, 0xCC]))
    }

    func testChannelDataBufferedUntilEstablished() throws {
        let factory = FakeFactory()
        var machine = TCPRelayStateMachine(factory: factory, isnGenerator: FixedISN())
        let flow = IPv4Flow(sourceAddress: 0x0A000002, sourcePort: 1234,
                            destinationAddress: 0x01010101, destinationPort: 443, transport: .tcp)
        _ = try machine.handle(packet: IPv4Packet(synPacket(src: v4(10, 0, 0, 2), srcPort: 1234, dst: v4(1, 1, 1, 1), dstPort: 443)))
        let rflow = RelayFlow(srcAddr: v4(10, 0, 0, 2), srcPort: 1234,
                              dstAddr: v4(1, 1, 1, 1), dstPort: 443, transport: .tcp)
        // Server answered before the phone's ACK: buffer, don't drop.
        XCTAssertTrue(machine.channelData(Data([0xAA]), for: rflow).isEmpty)
        // The ACK flushes the buffered bytes as a data packet.
        let flushed = try machine.handle(packet: IPv4Packet(ackPacket(flow: flow, seq: 1001, ack: 5001)))
        XCTAssertEqual(flushed.count, 1)
        let seg = try TCPParser.parse(Data(flushed[0].dropFirst(20)))
        XCTAssertEqual(seg.payload, Data([0xAA]))
    }

    func testChannelCloseSendsFin() throws {
        let factory = FakeFactory()
        var machine = TCPRelayStateMachine(factory: factory, isnGenerator: FixedISN())
        let flow = IPv4Flow(sourceAddress: 0x0A000002, sourcePort: 1234,
                            destinationAddress: 0x01010101, destinationPort: 443, transport: .tcp)
        _ = try machine.handle(packet: IPv4Packet(synPacket(src: v4(10, 0, 0, 2), srcPort: 1234, dst: v4(1, 1, 1, 1), dstPort: 443)))
        _ = try machine.handle(packet: IPv4Packet(ackPacket(flow: flow, seq: 1001, ack: 5001)))
        let rflow = RelayFlow(srcAddr: v4(10, 0, 0, 2), srcPort: 1234,
                              dstAddr: v4(1, 1, 1, 1), dstPort: 443, transport: .tcp)
        let pkts = machine.channelClosed(flow: rflow)
        XCTAssertEqual(pkts.count, 1)
        let seg = try TCPParser.parse(Data(pkts[0].dropFirst(20)))
        XCTAssertTrue(seg.flags.contains(.fin))
        XCTAssertEqual(seg.ack, 1001)
    }

    func testChannelDataUnknownFlowDropped() throws {
        let factory = FakeFactory()
        var machine = TCPRelayStateMachine(factory: factory, isnGenerator: FixedISN())
        let ghost = RelayFlow(srcAddr: v4(10, 0, 0, 9), srcPort: 9999,
                              dstAddr: v4(1, 1, 1, 1), dstPort: 443, transport: .tcp)
        XCTAssertTrue(machine.channelData(Data([0x01]), for: ghost).isEmpty)
        XCTAssertTrue(machine.channelClosed(flow: ghost).isEmpty)
    }

    func testOpenWiresChannelCallbacks() throws {
        let factory = FakeFactory()
        var machine = TCPRelayStateMachine(factory: factory, isnGenerator: FixedISN())
        var seen: [(RelayFlow, Data)] = []
        machine.onChannelData = { seen.append(($0, $1)) }
        _ = try machine.handle(packet: IPv4Packet(synPacket(src: v4(10, 0, 0, 2), srcPort: 1234, dst: v4(1, 1, 1, 1), dstPort: 443)))
        // Drive the captured onData closure as the SSH channel would.
        factory.capturedOnData?(Data([0x07]))
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen[0].0.srcPort, 1234)
        XCTAssertEqual(seen[0].1, Data([0x07]))
    }

    // MARK: - Round 8: IP options + checksum edge cases

    func testSynWithIPOptionsWorks() throws {
        // 24-byte IP header (4 bytes of options) — must not break TCP offset.
        let factory = FakeFactory()
        var machine = TCPRelayStateMachine(factory: factory, isnGenerator: FixedISN())

        var ip = [UInt8](repeating: 0, count: 24)
        ip[0] = 0x46 // version 4, IHL 6 (24 bytes)
        let total = 24 + 20 // no TCP payload
        ip[2] = UInt8(total >> 8); ip[3] = UInt8(total & 0xFF)
        ip[8] = 64; ip[9] = 6
        ip[12..<16] = [10, 0, 0, 2]
        ip[16..<20] = [1, 1, 1, 1]
        // 4 bytes of padding options [20..<24] already zero
        let csum = Checksum.ipHeader(ip)
        ip[10] = UInt8(csum >> 8); ip[11] = UInt8(csum & 0xFF)

        var tcp = [UInt8](repeating: 0, count: 20)
        tcp[0] = 0x04; tcp[1] = 0xD2 // port 1234
        tcp[2] = 0x01; tcp[3] = 0xBB // port 443
        tcp[12] = 0x50
        tcp[13] = 0x02 // SYN

        let replies = try machine.handle(packet: IPv4Packet(ip + tcp))
        XCTAssertEqual(replies.count, 1, "SYN-ACK emitted despite IP options")
        XCTAssertEqual(factory.opened.count, 1)
    }

    func testSynAckReplyVerifies() throws {
        // The SYN-ACK we emit must have valid IP and TCP checksums.
        let factory = FakeFactory()
        var machine = TCPRelayStateMachine(factory: factory, isnGenerator: FixedISN())

        let pkt = synPacket(src: v4(10, 0, 0, 2), srcPort: 1234, dst: v4(1, 1, 1, 1), dstPort: 443)
        let replies = try machine.handle(packet: IPv4Packet(pkt))
        XCTAssertEqual(replies.count, 1)

        let reply = replies[0]
        XCTAssertTrue(Checksum.isValidIPv4Packet(reply), "reply IP checksum valid")
        XCTAssertTrue(Checksum.isValidTCPSegment(packet: reply), "reply TCP checksum valid")
    }

    // MARK: - additional packet builders

    private func ackPacket(flow: IPv4Flow, seq: UInt32, ack: UInt32) -> [UInt8] {
        rawTCP(flow: flow, seq: seq, ack: ack, flags: 0x10, payload: []) // ACK
    }

    private func dataPacket(flow: IPv4Flow, seq: UInt32, ack: UInt32, payload: [UInt8]) -> [UInt8] {
        rawTCP(flow: flow, seq: seq, ack: ack, flags: 0x18, payload: payload) // PSH+ACK
    }

    private func dataNoAckPacket(flow: IPv4Flow, seq: UInt32, payload: [UInt8]) -> [UInt8] {
        rawTCP(flow: flow, seq: seq, ack: 0, flags: 0x08, payload: payload) // PSH, no ACK
    }

    private func finPacket(flow: IPv4Flow, seq: UInt32, ack: UInt32) -> [UInt8] {
        rawTCP(flow: flow, seq: seq, ack: ack, flags: 0x11, payload: []) // FIN+ACK
    }

    private func rstPacket(flow: IPv4Flow, seq: UInt32) -> [UInt8] {
        rawTCP(flow: flow, seq: seq, ack: 0, flags: 0x04, payload: []) // RST
    }

    private func rawTCP(flow: IPv4Flow, seq: UInt32, ack: UInt32, flags: UInt8, payload: [UInt8]) -> [UInt8] {
        var ip = [UInt8](repeating: 0, count: 20)
        ip[0] = 0x45
        let total = 20 + 20 + payload.count
        ip[2] = UInt8(total >> 8); ip[3] = UInt8(total & 0xFF)
        ip[8] = 64; ip[9] = 6
        ip[12..<16] = flow.sourceAddressBytes[0..<4]
        ip[16..<20] = flow.destinationAddressBytes[0..<4]
        let csum = Checksum.ipHeader(ip)
        ip[10] = UInt8(csum >> 8); ip[11] = UInt8(csum & 0xFF)

        var tcp = [UInt8](repeating: 0, count: 20)
        tcp[0] = UInt8(flow.sourcePort >> 8); tcp[1] = UInt8(flow.sourcePort & 0xFF)
        tcp[2] = UInt8(flow.destinationPort >> 8); tcp[3] = UInt8(flow.destinationPort & 0xFF)
        tcp[4] = UInt8(seq >> 24); tcp[5] = UInt8((seq >> 16) & 0xFF)
        tcp[6] = UInt8((seq >> 8) & 0xFF); tcp[7] = UInt8(seq & 0xFF)
        tcp[8] = UInt8(ack >> 24); tcp[9] = UInt8((ack >> 16) & 0xFF)
        tcp[10] = UInt8((ack >> 8) & 0xFF); tcp[11] = UInt8(ack & 0xFF)
        tcp[12] = 0x50
        tcp[13] = flags
        tcp[14] = 0xFF; tcp[15] = 0xFF
        return ip + tcp + payload
    }

    private func finPayloadPacket(flow: IPv4Flow, seq: UInt32, ack: UInt32, payload: [UInt8]) -> [UInt8] {
        rawTCP(flow: flow, seq: seq, ack: ack, flags: 0x19, payload: payload) // FIN+PSH+ACK
    }

    // MARK: - Duplicate detection (retransmit suppression)

    func testDuplicateDataNotForwardedToServer() throws {
        let factory = FakeFactory()
        var machine = TCPRelayStateMachine(factory: factory, isnGenerator: FixedISN())
        let flow = IPv4Flow(sourceAddress: 0x0A000002, sourcePort: 1234,
                            destinationAddress: 0x01010101, destinationPort: 443, transport: .tcp)

        _ = try machine.handle(packet: IPv4Packet(synPacket(src: v4(10, 0, 0, 2), srcPort: 1234, dst: v4(1, 1, 1, 1), dstPort: 443)))
        _ = try machine.handle(packet: IPv4Packet(ackPacket(flow: flow, seq: 1001, ack: 5001)))

        // Phone sends data.
        let s1 = try machine.handle(packet: IPv4Packet(dataPacket(flow: flow, seq: 1001, ack: 5001, payload: [0xDE, 0xAD])))
        XCTAssertEqual(s1.count, 1, "ACK for original")
        XCTAssertEqual(factory.channels.first?.value.sent.count, 1, "forwarded once")

        // Phone retransmits the same data.
        let s2 = try machine.handle(packet: IPv4Packet(dataPacket(flow: flow, seq: 1001, ack: 5001, payload: [0xDE, 0xAD])))
        XCTAssertEqual(s2.count, 1, "ACK for retransmit")
        XCTAssertEqual(factory.channels.first?.value.sent.count, 1, "NOT forwarded again — duplicate suppressed")

        // The ACK should reference peerSeq = 1003 (1001 + 2 bytes).
        let seg = try TCPParser.parse(Data(s2[0].dropFirst(20)))
        XCTAssertEqual(seg.ack, 1003)
    }

    func testPartialOverlapTrimsDuplicatePrefix() throws {
        let factory = FakeFactory()
        var machine = TCPRelayStateMachine(factory: factory, isnGenerator: FixedISN())
        let flow = IPv4Flow(sourceAddress: 0x0A000002, sourcePort: 1234,
                            destinationAddress: 0x01010101, destinationPort: 443, transport: .tcp)

        _ = try machine.handle(packet: IPv4Packet(synPacket(src: v4(10, 0, 0, 2), srcPort: 1234, dst: v4(1, 1, 1, 1), dstPort: 443)))
        _ = try machine.handle(packet: IPv4Packet(ackPacket(flow: flow, seq: 1001, ack: 5001)))

        // Phone sends 10 bytes [1000..1010).
        _ = try machine.handle(packet: IPv4Packet(dataPacket(flow: flow, seq: 1000, ack: 5001, payload: [UInt8](repeating: 0xAA, count: 10))))
        XCTAssertEqual(factory.channels.first?.value.sent.count, 1)

        // Partial overlap: phone retransmits [990..1015) — first 10 bytes are duplicate, last 5 are new.
        let s = try machine.handle(packet: IPv4Packet(dataPacket(flow: flow, seq: 990, ack: 5001, payload: [UInt8](repeating: 0xBB, count: 25))))
        XCTAssertEqual(s.count, 1, "ACK for partial overlap")
        // Only 5 new bytes should have been forwarded.
        XCTAssertEqual(factory.channels.first?.value.sent.count, 2, "original + new portion")
        XCTAssertEqual(factory.channels.first?.value.sent.last, Data([UInt8](repeating: 0xBB, count: 5)))
        // peerSeq should be 1015.
        let seg = try TCPParser.parse(Data(s[0].dropFirst(20)))
        XCTAssertEqual(seg.ack, 1015)
    }

    func testFullyDuplicateSegmentNoForward() throws {
        let factory = FakeFactory()
        var machine = TCPRelayStateMachine(factory: factory, isnGenerator: FixedISN())
        let flow = IPv4Flow(sourceAddress: 0x0A000002, sourcePort: 1234,
                            destinationAddress: 0x01010101, destinationPort: 443, transport: .tcp)

        _ = try machine.handle(packet: IPv4Packet(synPacket(src: v4(10, 0, 0, 2), srcPort: 1234, dst: v4(1, 1, 1, 1), dstPort: 443)))
        _ = try machine.handle(packet: IPv4Packet(ackPacket(flow: flow, seq: 1001, ack: 5001)))

        _ = try machine.handle(packet: IPv4Packet(dataPacket(flow: flow, seq: 1000, ack: 5001, payload: [0xAA, 0xBB])))
        XCTAssertEqual(factory.channels.first?.value.sent.count, 1)

        // Full duplicate: same seq, same data, no new bytes.
        let s = try machine.handle(packet: IPv4Packet(dataPacket(flow: flow, seq: 1000, ack: 5001, payload: [0xAA, 0xBB])))
        XCTAssertEqual(s.count, 1, "ACK for duplicate")
        XCTAssertEqual(factory.channels.first?.value.sent.count, 1, "not forwarded")
    }

    // MARK: - Out-of-order handling

    func testOutOfOrderSegmentNotForwarded() throws {
        let factory = FakeFactory()
        var machine = TCPRelayStateMachine(factory: factory, isnGenerator: FixedISN())
        let flow = IPv4Flow(sourceAddress: 0x0A000002, sourcePort: 1234,
                            destinationAddress: 0x01010101, destinationPort: 443, transport: .tcp)

        _ = try machine.handle(packet: IPv4Packet(synPacket(src: v4(10, 0, 0, 2), srcPort: 1234, dst: v4(1, 1, 1, 1), dstPort: 443)))
        _ = try machine.handle(packet: IPv4Packet(ackPacket(flow: flow, seq: 1001, ack: 5001)))

        // Phone sends [1000..1010), then jumps to [1020..1030) (missing 1010..1020).
        _ = try machine.handle(packet: IPv4Packet(dataPacket(flow: flow, seq: 1000, ack: 5001, payload: [UInt8](repeating: 0xAA, count: 10))))
        XCTAssertEqual(factory.channels.first?.value.sent.count, 1)

        let s = try machine.handle(packet: IPv4Packet(dataPacket(flow: flow, seq: 1020, ack: 5001, payload: [UInt8](repeating: 0xBB, count: 10))))
        XCTAssertEqual(s.count, 1, "ACK with current peerSeq (1010)")
        XCTAssertEqual(factory.channels.first?.value.sent.count, 1, "gap data NOT forwarded")
        let seg = try TCPParser.parse(Data(s[0].dropFirst(20)))
        XCTAssertEqual(seg.ack, 1010, "ACK still at highest contiguous byte")
    }

    // MARK: - FIN + payload in same segment

    func testFinWithPayloadForwardsDataAndAcksFin() throws {
        let factory = FakeFactory()
        var machine = TCPRelayStateMachine(factory: factory, isnGenerator: FixedISN())
        let flow = IPv4Flow(sourceAddress: 0x0A000002, sourcePort: 1234,
                            destinationAddress: 0x01010101, destinationPort: 443, transport: .tcp)

        _ = try machine.handle(packet: IPv4Packet(synPacket(src: v4(10, 0, 0, 2), srcPort: 1234, dst: v4(1, 1, 1, 1), dstPort: 443)))
        _ = try machine.handle(packet: IPv4Packet(ackPacket(flow: flow, seq: 1001, ack: 5001)))

        // FIN + 5 bytes of payload in same segment.  Data starts at seq=1001
        // (matching peerSeq after SYN consumed seq 1000).
        let s = try machine.handle(packet: IPv4Packet(finPayloadPacket(flow: flow, seq: 1001, ack: 5001, payload: [1, 2, 3, 4, 5])))

        // Data should have been forwarded to channel.
        XCTAssertEqual(factory.channels.first?.value.sent.first, Data([1, 2, 3, 4, 5]))
        // Should get ACK for the FIN (peerSeq = 1001 + 5 + 1 = 1007).
        XCTAssertFalse(s.isEmpty)
        let lastSeg = try TCPParser.parse(Data(s[s.count - 1].dropFirst(20)))
        XCTAssertTrue(lastSeg.flags.contains(.ack))
        XCTAssertEqual(lastSeg.ack, 1007, "ACK covers payload + FIN")
        // Channel should be closed.
        XCTAssertEqual(factory.channels.first?.value.closed, 1)
        XCTAssertEqual(machine.state(for: flow), .closing)
    }

    // MARK: - Half-close: phone FIN doesn't kill server→phone

    func testPhoneFinStillAllowsServerData() throws {
        let factory = FakeFactory()
        var machine = TCPRelayStateMachine(factory: factory, isnGenerator: FixedISN())
        let flow = IPv4Flow(sourceAddress: 0x0A000002, sourcePort: 1234,
                            destinationAddress: 0x01010101, destinationPort: 443, transport: .tcp)
        let rflow = RelayFlow(srcAddr: v4(10, 0, 0, 2), srcPort: 1234,
                              dstAddr: v4(1, 1, 1, 1), dstPort: 443, transport: .tcp)

        _ = try machine.handle(packet: IPv4Packet(synPacket(src: v4(10, 0, 0, 2), srcPort: 1234, dst: v4(1, 1, 1, 1), dstPort: 443)))
        _ = try machine.handle(packet: IPv4Packet(ackPacket(flow: flow, seq: 1001, ack: 5001)))

        // Phone sends FIN.
        _ = try machine.handle(packet: IPv4Packet(finPacket(flow: flow, seq: 1001, ack: 5001)))
        XCTAssertEqual(machine.state(for: flow), .closing)

        // Server data still comes through to phone even after phone FIN.
        let pkts = machine.channelData(Data([0xCC]), for: rflow)
        XCTAssertEqual(pkts.count, 1)
        let seg = try TCPParser.parse(Data(pkts[0].dropFirst(20)))
        XCTAssertEqual(seg.payload, Data([0xCC]))
    }

    // MARK: - Sequence wraparound

    func testSequenceWraparoundHandlesCorrectly() throws {
        let factory = FakeFactory()
        var machine = TCPRelayStateMachine(factory: factory, isnGenerator: FixedISN())
        let flow = IPv4Flow(sourceAddress: 0x0A000002, sourcePort: 1234,
                            destinationAddress: 0x01010101, destinationPort: 443, transport: .tcp)

        _ = try machine.handle(packet: IPv4Packet(synPacket(src: v4(10, 0, 0, 2), srcPort: 1234, dst: v4(1, 1, 1, 1), dstPort: 443)))

        // ACK with seq near UInt32.max to test wraparound.
        let nearMax: UInt32 = UInt32.max - 5
        _ = try machine.handle(packet: IPv4Packet(ackPacket(flow: flow, seq: nearMax, ack: 5001)))
        XCTAssertEqual(machine.state(for: flow), .established)

        // Data starting at peerSeq (nearMax), 10 bytes → wraps around UInt32.
        // seq=4294967290, len=10 → peerSeq wraps to 4294967290+10 = 4.
        let s = try machine.handle(packet: IPv4Packet(dataPacket(flow: flow, seq: nearMax, ack: 5001, payload: [UInt8](repeating: 0xFF, count: 10))))
        XCTAssertEqual(s.count, 1)
        let seg = try TCPParser.parse(Data(s[0].dropFirst(20)))
        XCTAssertEqual(seg.ack, 4, "peerSeq wrapped around correctly")
        XCTAssertEqual(factory.channels.first?.value.sent.count, 1)
    }

    // MARK: - Window Scale and backpressure

    func testWindowScaleParsedFromSyn() throws {
        // SYN with Window Scale option (kind=3, len=3, shift=7).
        let factory = FakeFactory()
        var machine = TCPRelayStateMachine(factory: factory, isnGenerator: FixedISN())
        let flow = IPv4Flow(sourceAddress: 0x0A000002, sourcePort: 1234,
                            destinationAddress: 0x01010101, destinationPort: 443, transport: .tcp)

        var ip = [UInt8](repeating: 0, count: 20)
        ip[0] = 0x45
        let tcpOpts: [UInt8] = [
            2, 4, 0x05, 0xB4,  // MSS=1460
            3, 3, 7,            // Window Scale shift=7
            1,                  // NOP
            4, 2                // SACK Permitted
        ]
        let tcpLen = 20 + tcpOpts.count
        let total = 20 + tcpLen
        ip[2] = UInt8(total >> 8); ip[3] = UInt8(total & 0xFF)
        ip[8] = 64; ip[9] = 6
        ip[12..<16] = [10, 0, 0, 2]
        ip[16..<20] = [1, 1, 1, 1]
        let csum = Checksum.ipHeader(ip)
        ip[10] = UInt8(csum >> 8); ip[11] = UInt8(csum & 0xFF)

        var tcp = [UInt8](repeating: 0, count: tcpLen)
        tcp[0] = 0x04; tcp[1] = 0xD2  // srcPort 1234
        tcp[2] = 0x01; tcp[3] = 0xBB  // dstPort 443
        tcp[12] = UInt8(((20 + tcpOpts.count) / 4)) << 4  // data offset
        tcp[13] = 0x02  // SYN
        tcp[14] = 0xFF; tcp[15] = 0xFF  // window
        for (i, b) in tcpOpts.enumerated() { tcp[20 + i] = b }

        let replies = try machine.handle(packet: IPv4Packet(ip + tcp))
        XCTAssertEqual(replies.count, 1, "SYN-ACK emitted")

        // Parse the SYN-ACK to verify it includes Window Scale option.
        let synAck = replies[0]
        let ipHeaderLen = Int(synAck[0] & 0x0F) * 4
        let tcpData = synAck[ipHeaderLen...]
        // TCP data offset should be > 20 (options present).
        let dataOffset = Int((tcpData[tcpData.startIndex + 12] >> 4) & 0x0F) * 4
        XCTAssertGreaterThan(dataOffset, 20, "SYN-ACK has TCP options")

        // Verify MSS and Window Scale are in the options.
        let opts = TCPParser.parseOptions(Data(tcpData[tcpData.startIndex + 20..<tcpData.startIndex + dataOffset]))
        XCTAssertEqual(opts.mss, 1400, "MSS option present")
        XCTAssertEqual(opts.windowScale, 7, "Window Scale option present")
    }

    func testOutstandingBytesTrackedOnAck() throws {
        let factory = FakeFactory()
        var machine = TCPRelayStateMachine(factory: factory, isnGenerator: FixedISN())
        let flow = IPv4Flow(sourceAddress: 0x0A000002, sourcePort: 1234,
                            destinationAddress: 0x01010101, destinationPort: 443, transport: .tcp)
        let rflow = RelayFlow(srcAddr: v4(10, 0, 0, 2), srcPort: 1234,
                              dstAddr: v4(1, 1, 1, 1), dstPort: 443, transport: .tcp)

        _ = try machine.handle(packet: IPv4Packet(synPacket(src: v4(10, 0, 0, 2), srcPort: 1234, dst: v4(1, 1, 1, 1), dstPort: 443)))
        _ = try machine.handle(packet: IPv4Packet(ackPacket(flow: flow, seq: 1001, ack: 5001)))

        // Server sends 100 bytes to phone.
        _ = machine.channelData(Data([UInt8](repeating: 0xAA, count: 100)), for: rflow)
        var stats = machine.flowStats().first { $0.flow == rflow }
        XCTAssertEqual(stats?.downBytes, 100)

        // Phone ACKs 50 bytes (ack advances from 5001 to 5051).
        _ = try machine.handle(packet: IPv4Packet(ackPacket(flow: flow, seq: 1001, ack: 5051)))

        // Server sends 200 more bytes — should be forwarded (window opened).
        _ = machine.channelData(Data([UInt8](repeating: 0xBB, count: 200)), for: rflow)
        stats = machine.flowStats().first { $0.flow == rflow }
        XCTAssertEqual(stats?.downBytes, 300, "all 300 bytes sent after ACK freed window")
    }

    func testSynAckIncludesWindowScaleOption() throws {
        let factory = FakeFactory()
        var machine = TCPRelayStateMachine(factory: factory, isnGenerator: FixedISN())
        let pkt = synPacket(src: v4(10, 0, 0, 2), srcPort: 1234, dst: v4(1, 1, 1, 1), dstPort: 443)
        let replies = try machine.handle(packet: IPv4Packet(pkt))
        XCTAssertEqual(replies.count, 1)

        // Verify SYN-ACK has Window Scale option.
        let synAck = replies[0]
        let ipHeaderLen = Int(synAck[0] & 0x0F) * 4
        let tcpData = synAck[ipHeaderLen...]
        let dataOffset = Int((tcpData[tcpData.startIndex + 12] >> 4) & 0x0F) * 4
        XCTAssertGreaterThan(dataOffset, 20, "SYN-ACK has TCP options")
        let opts = TCPParser.parseOptions(Data(tcpData[tcpData.startIndex + 20..<tcpData.startIndex + dataOffset]))
        XCTAssertEqual(opts.windowScale, 7, "SYN-ACK advertises window scale=7")
    }

    /// Regression: replies must travel SERVER -> PHONE. `TCPReplyBuilder`
    /// reverses the flow internally, so the state machine must pass the
    /// forward (phone->server) flow. A double reversal produced packets
    /// addressed phone->server, which iOS drops silently — on-device this
    /// looked like an "egress blackhole" (SYN retransmits every 1s,
    /// up=0B/down=0B on every flow) while the utun read counter climbed.
    func testRepliesAreAddressedServerToPhone() throws {
        let factory = FakeFactory()
        var machine = TCPRelayStateMachine(factory: factory, isnGenerator: FixedISN())
        let syn = synPacket(src: v4(10, 0, 0, 2), srcPort: 1234, dst: v4(1, 1, 1, 1), dstPort: 443)
        let replies = try machine.handle(packet: IPv4Packet(syn))
        XCTAssertEqual(replies.count, 1)
        let synAck = replies[0]
        XCTAssertEqual(synAck[0] >> 4, 4)
        XCTAssertEqual(Array(synAck[12..<16]), v4(1, 1, 1, 1), "SYN-ACK src must be the SERVER")
        XCTAssertEqual(Array(synAck[16..<20]), v4(10, 0, 0, 2), "SYN-ACK dst must be the PHONE")
        XCTAssertEqual(UInt16(synAck[20]) << 8 | UInt16(synAck[21]), 443, "SYN-ACK src port = server port")
        XCTAssertEqual(UInt16(synAck[22]) << 8 | UInt16(synAck[23]), 1234, "SYN-ACK dst port = phone port")
        XCTAssertTrue(Checksum.isValidIPv4Packet(synAck), "SYN-ACK IP checksum must verify")
        XCTAssertTrue(Checksum.isValidTCPSegment(packet: synAck), "SYN-ACK TCP checksum must verify")
    }
}
