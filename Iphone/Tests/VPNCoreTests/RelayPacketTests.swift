import XCTest
@testable import VPNCore

/// Phase A of the unprivileged relay track: raw packet tools. The relay owns
/// L3 (utun gives us IP packets), so it must parse TCP/UDP itself, answer
/// handshakes (SYN-ACK/RST) with correct checksums, and frame DNS-over-TCP.
/// Pure bytes in/out — fully unit-testable, no sockets.
final class RelayPacketTests: XCTestCase {

    // MARK: - helpers

    private func v4bytes(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> [UInt8] { [a, b, c, d] }

    private func tcpSegment(seq: UInt32 = 1000, ack: UInt32 = 0, flags: UInt8 = 0x02,
                            window: UInt16 = 65535, payload: [UInt8] = []) -> [UInt8] {
        // TCP header layout: [0..1] ports, [4..7] seq, [8..11] ack,
        // [12] data offset, [13] flags, [14..15] window.
        var h = [UInt8](repeating: 0, count: 20)
        h[12] = 0x50 // data offset 5, no options
        h[13] = flags
        h[14] = UInt8(window >> 8); h[15] = UInt8(window & 0xFF)
        h[4] = UInt8(seq >> 24); h[5] = UInt8((seq >> 16) & 0xFF)
        h[6] = UInt8((seq >> 8) & 0xFF); h[7] = UInt8(seq & 0xFF)
        h[8] = UInt8(ack >> 24); h[9] = UInt8((ack >> 16) & 0xFF)
        h[10] = UInt8((ack >> 8) & 0xFF); h[11] = UInt8(ack & 0xFF)
        return h + payload
    }

    // MARK: - TCP parsing

    func testParseTCPSyn() throws {
        let seg = try TCPParser.parse(Data(tcpSegment(seq: 12345, flags: 0x02)))
        XCTAssertEqual(seg.seq, 12345)
        XCTAssertEqual(seg.ack, 0)
        XCTAssertTrue(seg.flags.contains(.syn))
        XCTAssertFalse(seg.flags.contains(.ack))
        XCTAssertTrue(seg.payload.isEmpty)
    }

    func testParseTCPFlagsAndAck() throws {
        let seg = try TCPParser.parse(Data(tcpSegment(seq: 1, ack: 999, flags: 0x19)))
        XCTAssertTrue(seg.flags.contains(.fin))
        XCTAssertTrue(seg.flags.contains(.ack))
        XCTAssertTrue(seg.flags.contains(.psh))
        XCTAssertFalse(seg.flags.contains(.syn))
        XCTAssertFalse(seg.flags.contains(.rst))
        XCTAssertEqual(seg.ack, 999)
    }

    func testParseTCPTruncatedThrows() {
        XCTAssertThrowsError(try TCPParser.parse(Data([0x50, 0x02, 0x00])))
    }

    // MARK: - UDP parsing

    func testParseUDP() throws {
        var d = [UInt8](repeating: 0, count: 8) + [0xDE, 0xAD]
        d[0] = 0x1F; d[1] = 0x90 // src 8080
        d[2] = 0x00; d[3] = 0x35 // dst 53
        d[4] = 0x00; d[5] = 0x0A // length 10
        let u = try UDPParser.parse(Data(d))
        XCTAssertEqual(u.payload, Data([0xDE, 0xAD]))
    }

    // MARK: - IPv6 parsing

    func testParseIPv6TCP() throws {
        var p = [UInt8](repeating: 0, count: 40)
        p[0] = 0x60
        p[4] = 0x00; p[5] = 0x14 // payload length 20
        p[6] = 6 // TCP
        // src fd00::1, dst 2001:db8::1
        p[8] = 0xFD; p[23] = 0x01
        p[24] = 0x20; p[25] = 0x01; p[26] = 0x0D; p[27] = 0xB8; p[39] = 0x01
        p += tcpSegment()
        let parsed = try IPv6Parser.parse(Data(p))
        XCTAssertEqual(parsed.flow.transport, .tcp)
        XCTAssertEqual(parsed.flow.srcAddr.count, 16)
        XCTAssertEqual(parsed.flow.dstAddr.count, 16)
        XCTAssertTrue(parsed.flow.isV6)
    }

    func testParseIPv6RejectsNonTCPUDP() {
        var p = [UInt8](repeating: 0, count: 40)
        p[0] = 0x60; p[6] = 1 // ICMPv6
        XCTAssertThrowsError(try IPv6Parser.parse(Data(p)))
    }

    // MARK: - checksums (RFC 1071 vector + round-trip)

    func testIPChecksumMatchesRFC1071() {
        // RFC 1071 example header (checksum field zeroed): folded sum is
        // 0xDDF2, so the checksum (one's complement) is 0x220D.
        let header: [UInt8] = [0x00, 0x01, 0xF2, 0x03, 0xF4, 0xF5, 0xF6, 0xF7]
        XCTAssertEqual(Checksum.ipHeader(header), 0x220D)
    }

    func testBuiltSynAckVerifies() throws {
        let flow = RelayFlow(srcAddr: v4bytes(10, 0, 0, 2), srcPort: 1234,
                             dstAddr: v4bytes(1, 1, 1, 1), dstPort: 443, transport: .tcp)
        let pkt = try TCPReplyBuilder.synAck(flow: flow, isn: 5000, peerSeq: 1000)
        XCTAssertTrue(Checksum.isValidIPv4Packet(pkt))
        XCTAssertTrue(Checksum.isValidTCPSegment(packet: pkt))
    }

    func testCorruptedPacketFailsVerify() throws {
        let flow = RelayFlow(srcAddr: v4bytes(10, 0, 0, 2), srcPort: 1234,
                             dstAddr: v4bytes(1, 1, 1, 1), dstPort: 443, transport: .tcp)
        var pkt = try TCPReplyBuilder.synAck(flow: flow, isn: 5000, peerSeq: 1000)
        pkt[pkt.count - 1] ^= 0xFF
        XCTAssertFalse(Checksum.isValidTCPSegment(packet: pkt))
    }

    // MARK: - SYN-ACK / RST semantics

    func testSynAckMirrorsFlowAndAcksSyn() throws {
        let flow = RelayFlow(srcAddr: v4bytes(10, 0, 0, 2), srcPort: 1234,
                             dstAddr: v4bytes(1, 1, 1, 1), dstPort: 443, transport: .tcp)
        let pkt = try TCPReplyBuilder.synAck(flow: flow, isn: 5000, peerSeq: 1000)
        // Reply direction is reversed: server -> phone.
        let parsed = try IPv4Parser.parse(Data(pkt))
        XCTAssertEqual(parsed.flow.sourceAddress, (UInt32(1) << 24) | (UInt32(1) << 16) | (UInt32(1) << 8) | 1)
        XCTAssertEqual(parsed.flow.destinationPort, 1234)
        // The TCP *segment* starts after the 20-byte IP header (our builder
        // emits no IP options); parsed.payload is only the TCP data.
        let seg = try TCPParser.parse(Data(pkt.dropFirst(20)))
        XCTAssertTrue(seg.flags.contains(.syn))
        XCTAssertTrue(seg.flags.contains(.ack))
        XCTAssertEqual(seg.seq, 5000)
        XCTAssertEqual(seg.ack, 1001, "SYN consumes one sequence number")
    }

    func testRstHasNoPayload() throws {
        let flow = RelayFlow(srcAddr: v4bytes(10, 0, 0, 2), srcPort: 1234,
                             dstAddr: v4bytes(1, 1, 1, 1), dstPort: 80, transport: .tcp)
        let pkt = try TCPReplyBuilder.rst(flow: flow, seq: 0, ack: 8)
        let parsed = try IPv4Parser.parse(Data(pkt))
        let seg = try TCPParser.parse(Data(pkt.dropFirst(20)))
        XCTAssertTrue(seg.flags.contains(.rst))
        XCTAssertEqual(seg.seq, 0)
        XCTAssertEqual(seg.ack, 8)
        XCTAssertTrue(seg.payload.isEmpty)
    }

    func testDataSegmentRoundTrips() throws {
        let flow = RelayFlow(srcAddr: v4bytes(10, 0, 0, 2), srcPort: 1234,
                             dstAddr: v4bytes(1, 1, 1, 1), dstPort: 443, transport: .tcp)
        let pkt = try TCPReplyBuilder.data(flow: flow, seq: 100, ack: 50, payload: [0xDE, 0xAD])
        XCTAssertTrue(Checksum.isValidTCPSegment(packet: pkt))
        let seg = try TCPParser.parse(Data(pkt.dropFirst(20)))
        XCTAssertTrue(seg.flags.contains(.ack))
        XCTAssertTrue(seg.flags.contains(.psh))
        XCTAssertEqual(seg.payload, Data([0xDE, 0xAD]))
    }

    // MARK: - DNS-over-TCP codec

    func testDNSEncodePrependsLength() {
        let q = Data([0xAA, 0xBB, 0xCC])
        let enc = DNSOverTCP.encode(q)
        XCTAssertEqual(Array(enc), [0x00, 0x03, 0xAA, 0xBB, 0xCC])
    }

    func testDNSDecodeSplitsCoalescedAndKeepsRemainder() {
        let m1 = DNSOverTCP.encode(Data([0x01]))
        let m2 = DNSOverTCP.encode(Data([0x02, 0x03]))
        var stream = m1 + m2 + Data([0x00, 0x05, 0x09])
        let (msgs, rest) = DNSOverTCP.decode(stream)
        XCTAssertEqual(msgs.count, 2)
        XCTAssertEqual(rest, Data([0x00, 0x05, 0x09]))
    }
}
