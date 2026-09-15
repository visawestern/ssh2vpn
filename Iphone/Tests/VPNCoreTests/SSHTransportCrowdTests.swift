import XCTest
@testable import VPNCore

/// Crowd-blending guard: our CHANNEL_OPEN must advertise the same
/// window/maxpacket as OpenSSH (Termux/desktop ssh), not the NIOSSH default.
final class SSHTransportCrowdTests: XCTestCase {

    func testChannelPacketSizeMatchesOpenSSH() {
        XCTAssertEqual(
            SSHTransportFactory.channelMaximumPacketSize, 32768,
            "must stay 32768 — the OpenSSH maximum packet size; NIOSSH default is 128 KiB and stands out"
        )
    }

    func testAdvertisedWindowMatchesOpenSSH() {
        // NIOSSH couples window = 64x max packet; 64 * 32768 = 2 MiB = OpenSSH default window.
        XCTAssertEqual(SSHTransportFactory.channelMaximumPacketSize * 64, 2 * 1024 * 1024)
    }
}
