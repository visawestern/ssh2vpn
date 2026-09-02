import XCTest
@testable import VPNCore

final class RawPacketBridgeTests: XCTestCase {
    func testWrapsAndUnwrapsPacket() throws {
        let packet = Data([0x45, 0, 0, 20])
        let frame = try RawPacketBridge.outboundFrame(for: packet)
        XCTAssertEqual(frame.type, .packet)
        XCTAssertEqual(try RawPacketBridge.inboundPacket(from: frame), packet)
    }

    func testRejectsEmptyAndOversizedPackets() {
        XCTAssertThrowsError(try RawPacketBridge.outboundFrame(for: Data())) { XCTAssertEqual($0 as? RawPacketBridgeError, .emptyPacket) }
        XCTAssertThrowsError(try RawPacketBridge.outboundFrame(for: Data(repeating: 0, count: RawPacketBridge.maxPacketSize + 1))) { XCTAssertEqual($0 as? RawPacketBridgeError, .packetTooLarge) }
    }

    func testRejectsFlowFrameAndNonZeroStream() throws {
        let flow = try TransportFrame(type: .data, streamID: 0, payload: Data([1]))
        XCTAssertThrowsError(try RawPacketBridge.inboundPacket(from: flow)) { XCTAssertEqual($0 as? RawPacketBridgeError, .wrongFrameType) }
        let wrongStream = try TransportFrame(type: .packet, streamID: 8, payload: Data([1]))
        XCTAssertThrowsError(try RawPacketBridge.inboundPacket(from: wrongStream)) { XCTAssertEqual($0 as? RawPacketBridgeError, .nonZeroStreamID) }
    }
}
