import XCTest
import NIOCore
import NIOEmbedded
import NIOSSH
@testable import VPNCore

/// Phase C: SSH direct-tcpip channel wrapper. The relay opens a direct-tcpip
/// channel per TCP flow and splices bytes between utun and the SSH channel —
/// no privileged server code needed.
final class SSHRelayChannelTests: XCTestCase {

    func testDirectTCPIPChannelTypeHasCorrectTarget() throws {
        let addr = try SocketAddress(ipAddress: "10.0.0.2", port: 1234)
        let type = SSHChannelType.directTCPIP(.init(targetHost: "1.2.3.4", targetPort: 443,
                                                     originatorAddress: addr))
        if case .directTCPIP(let msg) = type {
            XCTAssertEqual(msg.targetHost, "1.2.3.4")
            XCTAssertEqual(msg.targetPort, 443)
        } else {
            XCTFail("expected directTCPIP")
        }
    }

    func testRelayFlowToDirectTCPIPMapping() throws {
        let flow = RelayFlow(srcAddr: [10, 0, 0, 2], srcPort: 1234,
                             dstAddr: [1, 1, 1, 1], dstPort: 443, transport: .tcp)
        let type = flow.directTCPIPChannelType()
        if case .directTCPIP(let msg) = type {
            XCTAssertEqual(msg.targetHost, "1.1.1.1")
            XCTAssertEqual(msg.targetPort, 443)
        } else {
            XCTFail("expected directTCPIP")
        }
    }

    // MARK: - Round 2b: wrapper behaviour

    func testWrapperForwardsChannelReadsToOnData() throws {
        let embedded = EmbeddedChannel()
        let wrapper = SSHRelayChannelWrapper()
        var received = [Data]()
        wrapper.onData = { received.append($0) }

        // Add the wrapper as a handler so it receives channelRead events.
        try embedded.pipeline.addHandler(wrapper).wait()

        // Push SSH channel data through the pipeline.
        var buf = embedded.allocator.buffer(capacity: 3)
        buf.writeBytes([0xDE, 0xAD, 0xBE])
        let channelData = SSHChannelData(type: .channel, data: .byteBuffer(buf))
        try embedded.pipeline.fireChannelRead(NIOAny(channelData))

        XCTAssertEqual(received, [Data([0xDE, 0xAD, 0xBE])])
    }

    func testWrapperSendWritesToChannel() throws {
        let embedded = EmbeddedChannel()
        let wrapper = SSHRelayChannelWrapper()

        // Attach first so the channel is established.
        try embedded.pipeline.addHandler(wrapper).wait()
        wrapper.send(Data([0x01, 0x02]))
        let written = try embedded.readOutbound(as: SSHChannelData.self)
        XCTAssertNotNil(written)
        if case .byteBuffer(var buf) = written?.data {
            XCTAssertEqual(buf.readBytes(length: buf.readableBytes), [0x01, 0x02])
        }
    }
}

private extension RelayFlow {
    /// Maps this flow to a direct-tcpip channel type targeting the flow's
    /// destination (the address the phone wants to reach).
    func directTCPIPChannelType() -> SSHChannelType {
        let originator: SocketAddress = (try? SocketAddress(ipAddress: srcAddr.map(String.init).joined(separator: "."),
                                                              port: Int(srcPort)))
            ?? (try? SocketAddress(ipAddress: "0.0.0.0", port: 0))!
        return SSHChannelType.directTCPIP(.init(
            targetHost: dstAddr.map(String.init).joined(separator: "."),
            targetPort: Int(dstPort),
            originatorAddress: originator))
    }
}
