import XCTest
@testable import VPNCore

final class FrameDecoderTests: XCTestCase {
    func testDecodesHeaderAndPayloadSplitAcrossReads() throws {
        let encoded = try TransportFrame(type: .data, streamID: 9, payload: Data([1, 2, 3])).encoded()
        var decoder = TransportFrameDecoder()
        XCTAssertTrue(try decoder.append(Data(encoded.prefix(5))).isEmpty)
        XCTAssertEqual(try decoder.append(Data(encoded.dropFirst(5))), [try TransportFrame(type: .data, streamID: 9, payload: Data([1, 2, 3]))])
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }

    func testDecodesSeveralFramesInOneRead() throws {
        let one = try TransportFrame(type: .ping).encoded()
        let two = try TransportFrame(type: .pong).encoded()
        var decoder = TransportFrameDecoder()
        var combined = one
        combined.append(two)
        XCTAssertEqual(try decoder.append(combined).map(\.type), [.ping, .pong])
    }

    func testRejectsBadFrameBeforeBufferGrowth() throws {
        var decoder = TransportFrameDecoder()
        XCTAssertThrowsError(try decoder.append(Data([255, 1, 0, 0] + Array(repeating: 0, count: 12)))) { error in
            XCTAssertEqual(error as? FrameError, .unsupportedVersion)
        }
    }
}
