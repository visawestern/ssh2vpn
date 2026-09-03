import XCTest
import NIOCore
import NIOEmbedded
import NIOSSH
@testable import VPNCore

/// Phase C Round 3: SSHRelayChannelFactory opens direct-tcpip channels and
/// wires them to the relay state machine.
final class SSHRelayFactoryTests: XCTestCase {

    func testFactoryOpensDirectTCPIPChannel() throws {
        let opener = MockChannelOpener()
        let factory = SSHRelayChannelFactory(opener: opener)
        let flow = RelayFlow(srcAddr: [10, 0, 0, 2], srcPort: 1234,
                             dstAddr: [1, 1, 1, 1], dstPort: 443, transport: .tcp)

        let ch = factory.open(flow: flow, onData: { _ in }, onClosed: {})
        XCTAssertNotNil(ch)
        XCTAssertEqual(opener.calls.count, 1)
    }

    func testFactoryMapsFlowToCorrectTarget() throws {
        let opener = MockChannelOpener()
        let factory = SSHRelayChannelFactory(opener: opener)
        let flow = RelayFlow(srcAddr: [10, 0, 0, 2], srcPort: 5555,
                             dstAddr: [8, 8, 8, 8], dstPort: 53, transport: .tcp)

        _ = factory.open(flow: flow, onData: { _ in }, onClosed: {})

        XCTAssertEqual(opener.calls.first?.targetHost, "8.8.8.8")
        XCTAssertEqual(opener.calls.first?.targetPort, 53)
    }
}

/// Records open calls so the test can assert on them.
final class MockChannelOpener: SSHChannelOpener {
    struct Call { let targetHost: String; let targetPort: Int }
    var calls = [Call]()

    func open(targetHost: String, targetPort: Int, originatorAddress: SocketAddress,
              onData: @escaping (Data) -> Void, onClosed: @escaping () -> Void) -> RelayChannel? {
        calls.append(Call(targetHost: targetHost, targetPort: targetPort))
        return nil
    }
}
