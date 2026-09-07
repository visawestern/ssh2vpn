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

    /// DNS queries arrive at the tunnel's OWN DNS IP (the flow dstAddr). The
    /// direct-tcpip channel must be opened to the configured upstream
    /// resolver instead — otherwise the SSH server tries to reach the phone's
    /// private tunnel address and every DNS lookup fails (observed live as
    /// "direct-tcpip open FAILED 10.203.113.2:53").
    func testDNSPathOpensUpstreamTargetInsteadOfTunnelLocalDst() throws {
        let opener = MockChannelOpener()
        let factory = SSHRelayChannelFactory(opener: opener)
        let tunnelDNSFlow = RelayFlow(srcAddr: [10, 203, 113, 2], srcPort: 54506,
                                      dstAddr: [10, 203, 113, 2], dstPort: 53, transport: .udp)

        _ = factory.open(flow: tunnelDNSFlow, targetHost: "94.140.14.14", targetPort: 53,
                         onData: { _ in }, onClosed: {})

        XCTAssertEqual(opener.calls.first?.targetHost, "94.140.14.14",
                       "DNS channel must target upstream, not the tunnel's own IP")
        XCTAssertEqual(opener.calls.first?.targetPort, 53)
    }

    func testFactoryDefaultsToFlowDstWithoutOverride() throws {
        let opener = MockChannelOpener()
        let factory = SSHRelayChannelFactory(opener: opener)
        let flow = RelayFlow(srcAddr: [10, 0, 0, 2], srcPort: 1234,
                             dstAddr: [1, 1, 1, 1], dstPort: 443, transport: .tcp)

        _ = factory.open(flow: flow, targetHost: nil, targetPort: nil,
                         onData: { _ in }, onClosed: {})

        XCTAssertEqual(opener.calls.first?.targetHost, "1.1.1.1")
        XCTAssertEqual(opener.calls.first?.targetPort, 443)
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
