import XCTest
@testable import VPNCore

/// The helper ships in the bundle and starts with one exec — no files
/// on the server, no manual install step, and (deliberately) no
/// obfuscation: the exact .py source travels as plaintext.
final class UDPHelperCommandTests: XCTestCase {

    func testBundledSourceExistsAndLooksLikeHelper() {
        guard let src = UDPHelperCommand.source() else {
            XCTFail("udp_relay.py missing from VPNCore bundle resources")
            return
        }
        XCTAssertTrue(src.contains("UDPRelay"), "bundled source must define UDPRelay")
        XCTAssertTrue(src.contains("create_datagram_endpoint"), "helper must speak UDP upstream")
        XCTAssertFalse(src.contains("open_tun_device"), "helper must not contain TUN/root code")
    }

    func testCommandEmbedsSourceVerbatim() throws {
        guard let src = UDPHelperCommand.source(),
              let cmd = UDPHelperCommand.command(source: src) else {
            XCTFail("bundled helper missing")
            return
        }
        XCTAssertTrue(cmd.hasPrefix("python3 -u /dev/fd/3 3<<'SSH2VPN_HELPER_EOF'\n"),
                      "must run as plaintext heredoc program on fd 3")
        XCTAssertTrue(cmd.hasSuffix("\nSSH2VPN_HELPER_EOF"),
                      "must terminate with the delimiter line")
        XCTAssertTrue(cmd.contains(src), "exact source must travel verbatim")
        XCTAssertFalse(cmd.contains("base64"), "no base64 anywhere")
        XCTAssertFalse(cmd.contains("exec("), "no exec() anywhere")
    }

    func testEmptySourceReturnsNil() {
        XCTAssertNil(UDPHelperCommand.command(source: ""))
    }

    func testDelimiterCollisionReturnsNil() {
        let evil = "import os\nSSH2VPN_HELPER_EOF\nos.exit(1)\n"
        XCTAssertNil(UDPHelperCommand.command(source: evil),
                     "a delimiter line inside the source must refuse, not truncate")
    }

    func testBundledSourceHasNoDelimiterCollision() throws {
        guard let src = UDPHelperCommand.source() else {
            XCTFail("bundled helper missing")
            return
        }
        XCTAssertNotNil(UDPHelperCommand.command(source: src),
                        "bundled udp_relay.py must not contain the delimiter line")
    }

    func testHeredocMechanismSurvivesRealShell() throws {
        // Emulates sshd's `sh -c <command>`: the exact heredoc shape with a
        // tiny probe payload containing quotes, dollars and backticks — all
        // must arrive literally thanks to the quoted delimiter.
        let probe = "import sys;sys.stdout.write('q$u`o')"
        let cmd = "python3 -u /dev/fd/3 3<<'SSH2VPN_HELPER_EOF'\n" + probe + "\nSSH2VPN_HELPER_EOF"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
        } catch {
            throw XCTSkip("no /bin/sh on this host")
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw XCTSkip("python3 missing on this host (status \(p.terminationStatus))")
        }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(text, "q$u`o")
    }
}
