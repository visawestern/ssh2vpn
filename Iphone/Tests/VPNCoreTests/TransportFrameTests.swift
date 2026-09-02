import XCTest
@testable import VPNCore

final class TransportFrameTests: XCTestCase {
    func testRoundTripPreservesTypeStreamAndPayload() throws {
        let original = try TransportFrame(type: .data, streamID: 0x0102030405060708, payload: Data([0, 1, 2, 255]))
        XCTAssertEqual(try TransportFrame.decode(original.encoded()), original)
    }

    func testRawPacketFrameUsesReservedStreamZero() throws {
        let packet = try TransportFrame(type: .packet, payload: Data([0x45, 0, 0, 20]))
        XCTAssertEqual(try TransportFrame.decode(packet.encoded()), packet)
        XCTAssertEqual(packet.streamID, 0)
    }

    func testHelloFrameCarriesSessionNonce() throws {
        let nonce = Data(repeating: 0xA5, count: 16)
        let frame = try TransportFrame(type: .hello, payload: nonce)
        XCTAssertEqual(try TransportFrame.decode(frame.encoded()), frame)
    }

    func testRejectsTruncatedHeader() {
        XCTAssertThrowsError(try TransportFrame.decode(Data(repeating: 0, count: TransportFrame.headerSize - 1))) { error in
            XCTAssertEqual(error as? FrameError, .incomplete)
        }
    }

    func testRejectsUnsupportedVersion() throws {
        var encoded = try TransportFrame(type: .ping).encoded()
        encoded[0] = 99
        XCTAssertThrowsError(try TransportFrame.decode(encoded)) { error in
            XCTAssertEqual(error as? FrameError, .unsupportedVersion)
        }
    }

    func testRejectsUnknownFrameType() throws {
        var encoded = try TransportFrame(type: .ping).encoded()
        encoded[1] = 255
        XCTAssertThrowsError(try TransportFrame.decode(encoded)) { error in
            XCTAssertEqual(error as? FrameError, .unknownType)
        }
    }

    func testRejectsPayloadLargerThanProtocolLimit() {
        XCTAssertThrowsError(try TransportFrame(type: .data, payload: Data(repeating: 1, count: TransportFrame.maxPayloadSize + 1))) { error in
            XCTAssertEqual(error as? FrameError, .payloadTooLarge)
        }
    }

    func testRejectsDeclaredLengthMismatch() throws {
        var encoded = try TransportFrame(type: .data, payload: Data([1, 2])).encoded()
        encoded[15] = 3
        XCTAssertThrowsError(try TransportFrame.decode(encoded)) { error in
            XCTAssertEqual(error as? FrameError, .incomplete)
        }
    }

    func testRejectsNonZeroReservedBits() throws {
        var encoded = try TransportFrame(type: .ping).encoded()
        encoded[2] = 1
        XCTAssertThrowsError(try TransportFrame.decode(encoded)) { error in
            XCTAssertEqual(error as? FrameError, .nonZeroReservedBits)
        }
    }
}
