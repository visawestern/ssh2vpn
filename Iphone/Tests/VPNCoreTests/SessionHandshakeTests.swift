import XCTest
@testable import VPNCore

final class SessionHandshakeTests: XCTestCase {
    private func ack(nonce: Data, status: UInt8 = 0) -> TransportFrame {
        try! TransportFrame(type: .helloAck, payload: nonce + Data([status]))
    }

    func testAcceptsExactAckOnce() throws {
        let nonce = Data(repeating: 0x42, count: 16)
        var handshake = SessionHandshake(nonce: nonce)

        XCTAssertTrue(try handshake.accept(ack(nonce: nonce)))
        XCTAssertEqual(handshake.state, .authenticated)
    }

    func testRejectsProbeFailureBit() throws {
        let nonce = Data(repeating: 0x55, count: 16)
        var handshake = SessionHandshake(nonce: nonce)

        XCTAssertThrowsError(try handshake.accept(ack(nonce: nonce, status: 1))) { error in
            XCTAssertEqual(error as? SessionHandshake.Error, .probeFailed)
        }
        XCTAssertEqual(handshake.state, .waiting)
    }

    func testRejectsMissingProbeByte() throws {
        let nonce = Data(repeating: 0x55, count: 16)
        var handshake = SessionHandshake(nonce: nonce)
        let ack = try TransportFrame(type: .helloAck, payload: nonce)

        XCTAssertThrowsError(try handshake.accept(ack)) { error in
            XCTAssertEqual(error as? SessionHandshake.Error, .nonceMismatch)
        }
    }

    func testRejectsWrongNonce() throws {
        var handshake = SessionHandshake(nonce: Data(repeating: 1, count: 16))

        XCTAssertThrowsError(try handshake.accept(ack(nonce: Data(repeating: 2, count: 16)))) { error in
            XCTAssertEqual(error as? SessionHandshake.Error, .nonceMismatch)
        }
        XCTAssertEqual(handshake.state, .waiting)
    }

    func testRejectsAckOnNonZeroStream() throws {
        var handshake = SessionHandshake(nonce: Data(repeating: 1, count: 16))
        let ack = try TransportFrame(type: .helloAck, streamID: 9, payload: handshake.nonce + Data([0]))

        XCTAssertThrowsError(try handshake.accept(ack)) { error in
            XCTAssertEqual(error as? SessionHandshake.Error, .wrongStream)
        }
    }

    func testRejectsReplayAfterAuthentication() throws {
        let nonce = Data(repeating: 7, count: 16)
        var handshake = SessionHandshake(nonce: nonce)
        let ack = ack(nonce: nonce)
        _ = try handshake.accept(ack)

        XCTAssertThrowsError(try handshake.accept(ack)) { error in
            XCTAssertEqual(error as? SessionHandshake.Error, .replayedAcknowledgement)
        }
    }

    func testRejectsNonAckBeforeAuthentication() throws {
        var handshake = SessionHandshake(nonce: Data(repeating: 3, count: 16))
        let ping = try TransportFrame(type: .ping)

        XCTAssertThrowsError(try handshake.accept(ping)) { error in
            XCTAssertEqual(error as? SessionHandshake.Error, .unexpectedFrame)
        }
    }
}