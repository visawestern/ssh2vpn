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
        func send(_ data: Data) { sent.append(data) }
        func close() { closed += 1 }
    }

    final class FakeFactory: RelayChannelFactory {
        var channels = [String: FakeChannel]()
        var opened = [String]()

        func open(flow: RelayFlow, onData: @escaping (Data) -> Void, onClosed: @escaping () -> Void) -> RelayChannel {
            let key = "\(flow.srcPort)->\(flow.dstAddr.map(String.init).joined(separator: ".")):\(flow.dstPort)"
            let ch = channels[key] ?? FakeChannel()
            channels[key] = ch
            opened.append(key)
            return ch
        }
    }

    struct FixedISN: ISNGenerator { func next() -> UInt32 { 5000 } }

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

    func testNonSynOnUnknownFlowIsIgnored() throws {
        let factory = FakeFactory()
        var machine = TCPRelayStateMachine(factory: factory, isnGenerator: FixedISN())
        let flow = IPv4Flow(sourceAddress: 0x0A000002, sourcePort: 1234,
                            destinationAddress: 0x01010101, destinationPort: 443, transport: .tcp)

        // ACK without prior SYN — should be ignored
        let replies = try machine.handle(packet: IPv4Packet(ackPacket(flow: flow, seq: 100, ack: 200)))
        XCTAssertTrue(replies.isEmpty)
        XCTAssertNil(machine.state(for: flow))
        XCTAssertEqual(factory.opened.count, 0)
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
}
