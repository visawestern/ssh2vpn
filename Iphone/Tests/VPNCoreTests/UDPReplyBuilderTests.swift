import XCTest
@testable import VPNCore

/// UDP reply builder for the relay: DNS answers (and future UDP flows) must
/// come back as well-formed IPv4/UDP packets with valid checksums, or the
/// phone stack drops them silently.
final class UDPReplyBuilderTests: XCTestCase {

    private func v4(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> [UInt8] { [a, b, c, d] }

    func testUDPReplySwapsDirection() throws {
        let flow = RelayFlow(srcAddr: v4(10, 0, 0, 2), srcPort: 1234,
                             dstAddr: v4(8, 8, 8, 8), dstPort: 53, transport: .udp)
        let pkt = try UDPReplyBuilder.reply(flow: flow, payload: [0xDE, 0xAD])
        let parsed = try IPv4Parser.parse(Data(pkt))
        // Reply direction: server -> phone.
        XCTAssertEqual(parsed.flow.sourceAddress, 0x08080808)
        XCTAssertEqual(parsed.flow.destinationPort, 1234)
        // The UDP datagram starts after the 20-byte IP header (parsed.payload
        // is only the bytes past the UDP header).
        let udp = try UDPParser.parse(Data(pkt.dropFirst(20)))
        XCTAssertEqual(udp.payload, Data([0xDE, 0xAD]))
    }

    func testUDPReplyChecksumVerifies() throws {
        let flow = RelayFlow(srcAddr: v4(10, 0, 0, 2), srcPort: 1234,
                             dstAddr: v4(8, 8, 8, 8), dstPort: 53, transport: .udp)
        let pkt = try UDPReplyBuilder.reply(flow: flow, payload: [0x01, 0x02, 0x03])
        XCTAssertTrue(Checksum.isValidIPv4Packet(pkt))
        XCTAssertTrue(Checksum.isValidUDPDatagram(packet: pkt))
    }

    func testCorruptedUDPChecksumFails() throws {
        let flow = RelayFlow(srcAddr: v4(10, 0, 0, 2), srcPort: 1234,
                             dstAddr: v4(8, 8, 8, 8), dstPort: 53, transport: .udp)
        var pkt = try UDPReplyBuilder.reply(flow: flow, payload: [0x01])
        pkt[pkt.count - 1] ^= 0xFF
        XCTAssertFalse(Checksum.isValidUDPDatagram(packet: pkt))
    }
}
