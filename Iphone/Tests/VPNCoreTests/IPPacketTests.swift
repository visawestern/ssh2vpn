import XCTest
@testable import VPNCore

final class IPPacketTests: XCTestCase {
    func testParsesIPv4TCPPayload() throws {
        let packet = makePacket(protocolNumber: 6, sourcePort: 1234, destinationPort: 443, payload: Data([7, 8]))
        let parsed = try IPv4Parser.parse(packet)
        XCTAssertEqual(parsed.flow.transport, .tcp)
        XCTAssertEqual(parsed.flow.sourcePort, 1234)
        XCTAssertEqual(parsed.flow.destinationPort, 443)
        XCTAssertEqual(parsed.payload, Data([7, 8]))
    }

    func testParsesIPv4UDPPayload() throws {
        let packet = makePacket(protocolNumber: 17, sourcePort: 5000, destinationPort: 53, payload: Data([1, 2, 3]))
        let parsed = try IPv4Parser.parse(packet)
        XCTAssertEqual(parsed.flow.transport, .udp)
        XCTAssertEqual(parsed.payload, Data([1, 2, 3]))
    }

    func testRejectsTruncatedAndUnsupportedPackets() {
        XCTAssertThrowsError(try IPv4Parser.parse(Data(repeating: 0, count: 19))) { XCTAssertEqual($0 as? IPPacketError, .empty) }
        var unsupported = Data(repeating: 0, count: 20)
        unsupported[0] = 0x60
        XCTAssertThrowsError(try IPv4Parser.parse(unsupported)) { XCTAssertEqual($0 as? IPPacketError, .unsupportedVersion) }
    }

    func testRejectsInvalidTotalLength() {
        var packet = makePacket(protocolNumber: 17, sourcePort: 1, destinationPort: 2, payload: Data())
        packet[2] = 0
        packet[3] = 100
        XCTAssertThrowsError(try IPv4Parser.parse(packet)) { XCTAssertEqual($0 as? IPPacketError, .invalidTotalLength) }
    }

    private func makePacket(protocolNumber: UInt8, sourcePort: UInt16, destinationPort: UInt16, payload: Data) -> Data {
        let transportHeaderLength = protocolNumber == 6 ? 20 : 8
        let totalLength = 20 + transportHeaderLength + payload.count
        var packet = Data(repeating: 0, count: totalLength)
        packet[0] = 0x45
        packet[2] = UInt8(totalLength >> 8)
        packet[3] = UInt8(totalLength & 0xff)
        packet[9] = protocolNumber
        packet[12...15] = Data([10, 0, 0, 2])
        packet[16...19] = Data([1, 1, 1, 1])
        packet[20] = UInt8(sourcePort >> 8)
        packet[21] = UInt8(sourcePort & 0xff)
        packet[22] = UInt8(destinationPort >> 8)
        packet[23] = UInt8(destinationPort & 0xff)
        if protocolNumber == 6 { packet[32] = 0x50 }
        packet[24...27] = Data(repeating: 0, count: 4)
        packet.replaceSubrange((20 + transportHeaderLength)..<totalLength, with: payload)
        return packet
    }
}
