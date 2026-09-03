import XCTest
import NIOCore
@testable import VPNCore

/// Tests the stderr preview attached to unexpected channel data: when the
/// server talks back outside the framed protocol (typically a gateway.py
/// traceback on stderr), the app dump must show WHAT it said, not just that
/// something arrived.
final class ChannelDataPreviewTests: XCTestCase {

    private func buffer(_ string: String) -> ByteBuffer {
        var buf = ByteBufferAllocator().buffer(capacity: string.utf8.count)
        buf.writeString(string)
        return buf
    }

    func testStderrTextIsPreserved() {
        let data = SSHChannelData(type: .stdErr, data: .byteBuffer(buffer("Traceback (most recent call last): OSError")))
        let preview = ChannelDataPreview.text(of: data)
        XCTAssertTrue(preview.contains("Traceback"))
        XCTAssertTrue(preview.contains("OSError"))
    }

    func testLongOutputIsTruncated() {
        let big = String(repeating: "x", count: 1000)
        let data = SSHChannelData(type: .stdErr, data: .byteBuffer(buffer(big)))
        let preview = ChannelDataPreview.text(of: data, limit: 100)
        XCTAssertLessThanOrEqual(preview.count, 110)
        XCTAssertTrue(preview.hasSuffix("…"))
    }

    func testEmptyPayloadIsMarked() {
        let data = SSHChannelData(type: .stdErr, data: .byteBuffer(buffer("")))
        XCTAssertEqual(ChannelDataPreview.text(of: data), "<empty>")
    }

    func testNonUTF8FallsBackToHex() {
        var buf = ByteBufferAllocator().buffer(capacity: 3)
        buf.writeBytes([0xFF, 0xFE, 0xFD] as [UInt8])
        let data = SSHChannelData(type: .stdErr, data: .byteBuffer(buf))
        let preview = ChannelDataPreview.text(of: data)
        XCTAssertTrue(preview.contains("ff fe fd"))
    }

    func testExtendedTypeDescriptionSurvives() {
        // The kind string travels alongside the preview so the dump shows
        // whether it was stderr or some other extended-data code.
        XCTAssertTrue("\(SSHChannelData.DataType.stdErr)".contains("stdErr"))
    }
}
