import XCTest
@testable import VPNCore

final class TransportFuzzTests: XCTestCase {
    func testDeterministicMalformedCorpusNeverProducesAnInvalidFrame() throws {
        var generator = LCG(seed: 0xC0DEC0DE)
        for _ in 0..<1_000 {
            let length = Int(generator.next() % 256)
            var bytes = Data((0..<length).map { _ in UInt8(truncatingIfNeeded: generator.next()) })
            if bytes.count >= TransportFrame.headerSize {
                // Exercise plausible headers as well as arbitrary garbage.
                bytes[0] = TransportFrame.protocolVersion
                bytes[1] = UInt8(truncatingIfNeeded: generator.next() % 11)
            }
            var decoder = TransportFrameDecoder()
            do {
                let frames = try decoder.append(bytes)
                for frame in frames {
                    XCTAssertLessThanOrEqual(frame.payload.count, TransportFrame.maxPayloadSize)
                }
            } catch {
                XCTAssertTrue(error is FrameError)
            }
        }
    }
}

private struct LCG {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
