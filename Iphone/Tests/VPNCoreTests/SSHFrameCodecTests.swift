import NIOCore
import NIOEmbedded
import NIOSSH
import XCTest
@testable import VPNCore

final class SSHFrameCodecTests: XCTestCase {
    func testCodecWritesOurFrameAsSSHChannelData() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.addHandler(SSHFrameCodec()).wait()
        let frame = try TransportFrame(type: .ping)
        XCTAssertTrue(try channel.writeOutbound(frame).isFull)
        let sshData = try XCTUnwrap(channel.readOutbound(as: SSHChannelData.self))
        XCTAssertEqual(sshData.type, .channel)
        guard case .byteBuffer(let buffer) = sshData.data else { return XCTFail("expected byte buffer") }
        XCTAssertEqual(try TransportFrame.decode(Data(buffer.readableBytesView)), frame)
        XCTAssertTrue(try channel.finish().isClean)
    }

    func testCodecReassemblesFragmentedSSHData() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.addHandler(SSHFrameCodec()).wait()
        let encoded = try TransportFrame(type: .pong).encoded()
        var first = channel.allocator.buffer(capacity: 5)
        first.writeBytes(encoded.prefix(5))
        var second = channel.allocator.buffer(capacity: encoded.count - 5)
        second.writeBytes(encoded.dropFirst(5))
        XCTAssertTrue(try channel.writeInbound(SSHChannelData(type: .channel, data: .byteBuffer(first))).isEmpty)
        XCTAssertTrue(try channel.writeInbound(SSHChannelData(type: .channel, data: .byteBuffer(second))).isFull)
        XCTAssertEqual(try channel.readInbound(as: TransportFrame.self), try TransportFrame(type: .pong))
        XCTAssertTrue(try channel.finish().isClean)
    }
}
