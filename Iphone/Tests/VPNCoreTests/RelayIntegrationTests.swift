import XCTest
@testable import VPNCore

/// Phase C Round 4: full integration — state machine drives the factory,
/// which opens channels. Verifies the complete SYN → channel → SYN-ACK
/// cycle works end-to-end with fakes.
final class RelayIntegrationTests: XCTestCase {

    final class RecordingFactory: RelayChannelFactory {
        struct FlowRecord { let flow: RelayFlow }
        var openedFlows = [FlowRecord]()
        var channels = [String: FakeChannel]()

        func open(flow: RelayFlow, onData: @escaping (Data) -> Void, onClosed: @escaping () -> Void) -> RelayChannel {
            openedFlows.append(FlowRecord(flow: flow))
            let ch = FakeChannel()
            channels["\(flow.srcPort)->\(flow.dstPort)"] = ch
            return ch
        }
    }

    final class FakeChannel: RelayChannel {
        var sent = [Data]()
        var closed = 0
        func send(_ data: Data) { sent.append(data) }
        func close() { closed += 1 }
    }

    struct FixedISN: ISNGenerator { func next() -> UInt32 { 5000 } }

    private func v4(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> [UInt8] { [a, b, c, d] }

    private func synPacket(src: [UInt8], srcPort: UInt16, dst: [UInt8], dstPort: UInt16) -> [UInt8] {
        var ip = [UInt8](repeating: 0, count: 20)
        ip[0] = 0x45
        ip[2] = 0; ip[3] = 40
        ip[8] = 64; ip[9] = 6
        ip[12..<16] = src[0..<4]
        ip[16..<20] = dst[0..<4]
        let csum = Checksum.ipHeader(ip)
        ip[10] = UInt8(csum >> 8); ip[11] = UInt8(csum & 0xFF)

        var tcp = [UInt8](repeating: 0, count: 20)
        tcp[0] = UInt8(srcPort >> 8); tcp[1] = UInt8(srcPort & 0xFF)
        tcp[2] = UInt8(dstPort >> 8); tcp[3] = UInt8(dstPort & 0xFF)
        tcp[12] = 0x50
        tcp[13] = 0x02 // SYN
        tcp[14] = 0xFF; tcp[15] = 0xFF
        return ip + tcp
    }

    func testStateMachineUsesFactoryOnSyn() throws {
        let factory = RecordingFactory()
        var machine = TCPRelayStateMachine(factory: factory, isnGenerator: FixedISN())

        let pkt = synPacket(src: v4(10, 0, 0, 2), srcPort: 1234, dst: v4(1, 1, 1, 1), dstPort: 443)
        let replies = try machine.handle(packet: IPv4Packet(pkt))

        XCTAssertEqual(factory.openedFlows.count, 1, "factory opened one channel")
        XCTAssertEqual(replies.count, 1, "SYN-ACK emitted")
        XCTAssertEqual(factory.openedFlows.first?.flow.srcPort, 1234)
        XCTAssertEqual(factory.openedFlows.first?.flow.dstPort, 443)
    }

    func testFullHandshakeCycle() throws {
        let factory = RecordingFactory()
        var machine = TCPRelayStateMachine(factory: factory, isnGenerator: FixedISN())
        let flow = IPv4Flow(sourceAddress: 0x0A000002, sourcePort: 1234,
                            destinationAddress: 0x01010101, destinationPort: 443, transport: .tcp)

        // SYN
        _ = try machine.handle(packet: IPv4Packet(synPacket(src: v4(10, 0, 0, 2), srcPort: 1234, dst: v4(1, 1, 1, 1), dstPort: 443)))
        XCTAssertEqual(machine.state(for: flow), .synReceived)

        // ACK
        var ip = [UInt8](repeating: 0, count: 20)
        ip[0] = 0x45; ip[2] = 0; ip[3] = 40; ip[8] = 64; ip[9] = 6
        ip[12..<16] = v4(10, 0, 0, 2)[0..<4]
        ip[16..<20] = v4(1, 1, 1, 1)[0..<4]
        let csum = Checksum.ipHeader(ip)
        ip[10] = UInt8(csum >> 8); ip[11] = UInt8(csum & 0xFF)
        var tcp = [UInt8](repeating: 0, count: 20)
        tcp[0] = 0x04; tcp[1] = 0xD2 // 1234
        tcp[2] = 0x01; tcp[3] = 0xBB // 443
        tcp[4] = 0; tcp[5] = 0; tcp[6] = 0; tcp[7] = 1 // seq 1 (simplified)
        tcp[8] = 0; tcp[9] = 0; tcp[10] = 0x13; tcp[11] = 0x89 // ack 5001
        tcp[12] = 0x50; tcp[13] = 0x10 // ACK
        tcp[14] = 0xFF; tcp[15] = 0xFF
        _ = try machine.handle(packet: IPv4Packet(ip + tcp))

        XCTAssertEqual(machine.state(for: flow), .established)
    }
}
