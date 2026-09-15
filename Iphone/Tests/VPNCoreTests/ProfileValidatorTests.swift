import XCTest
@testable import VPNCore

final class ProfileValidatorTests: XCTestCase {

    // MARK: - Port Validation Tests (Garbage & Boundary)

    func testValidPorts() throws {
        XCTAssertEqual(try ProfileValidator.validatePort("22"), 22)
        XCTAssertEqual(try ProfileValidator.validatePort(" 22 "), 22)
        XCTAssertEqual(try ProfileValidator.validatePort("1"), 1)
        XCTAssertEqual(try ProfileValidator.validatePort("443"), 443)
        XCTAssertEqual(try ProfileValidator.validatePort("65535"), 65535)
    }

    func testEmptyAndWhitespacePort() {
        XCTAssertThrowsError(try ProfileValidator.validatePort("")) { error in
            XCTAssertEqual(error as? ProfileValidationError, .emptyPort)
        }
        XCTAssertThrowsError(try ProfileValidator.validatePort("   ")) { error in
            XCTAssertEqual(error as? ProfileValidationError, .emptyPort)
        }
    }

    func testGarbageTextPort() {
        let garbageInputs = ["abc", "22a", "ssh", "port22", "22.5", "0x16", "NaN", "Infinity", "!@#$", "22; rm -rf /"]
        for input in garbageInputs {
            XCTAssertThrowsError(try ProfileValidator.validatePort(input), "Expected error for: \(input)") { error in
                XCTAssertEqual(error as? ProfileValidationError, .invalidPortFormat)
            }
        }
    }

    func testBoundaryAndOutOfRangePorts() {
        let outOfRangeInputs = ["0", "-1", "-22", "65536", "70000", "9999999999999999999999"]
        for input in outOfRangeInputs {
            XCTAssertThrowsError(try ProfileValidator.validatePort(input), "Expected error for: \(input)") { error in
                guard case .portOutOfRange? = error as? ProfileValidationError else {
                    XCTFail("Expected portOutOfRange for \(input), got \(error)")
                    return
                }
            }
        }
    }

    // MARK: - Host / Address Validation Tests

    func testValidHosts() throws {
        XCTAssertEqual(try ProfileValidator.validateHost("192.168.1.1"), "192.168.1.1")
        XCTAssertEqual(try ProfileValidator.validateHost("10.0.0.1"), "10.0.0.1")
        XCTAssertEqual(try ProfileValidator.validateHost("example.com"), "example.com")
        XCTAssertEqual(try ProfileValidator.validateHost("vpn.server-01.example.org"), "vpn.server-01.example.org")
        XCTAssertEqual(try ProfileValidator.validateHost(" 1.1.1.1 "), "1.1.1.1")
    }

    func testEmptyHost() {
        XCTAssertThrowsError(try ProfileValidator.validateHost("")) { error in
            XCTAssertEqual(error as? ProfileValidationError, .emptyHost)
        }
        XCTAssertThrowsError(try ProfileValidator.validateHost("   ")) { error in
            XCTAssertEqual(error as? ProfileValidationError, .emptyHost)
        }
    }

    func testGarbageHostInputs() {
        let garbageHosts = [
            "http://example.com",
            "https://192.168.1.1",
            "example .com",
            "host; rm -rf",
            "host$name",
            "host`whoami`",
            "host\nname",
            "host|pipe",
            "192.168.1.999",
            "192.168.1",
            "-invalid-host.com"
        ]
        for host in garbageHosts {
            XCTAssertThrowsError(try ProfileValidator.validateHost(host), "Expected error for host: \(host)")
        }
    }

    func testHostRejectsInvisibleAndSpoofingScalars() {
        let spoofedHosts = [
            "example\u{200B}.com",      // zero-width space
            "example\u{FEFF}.com",      // BOM
            "\u{202A}example.com",      // bidi embedding
            "example.com\u{2067}",      // RTL isolate
            "ex\u{00AD}ample.com",      // soft hyphen
            "ex\u{E000}ample.com",      // private use
            "ex\u{FFFE}ample.com"       // noncharacter
        ]
        for host in spoofedHosts {
            XCTAssertThrowsError(try ProfileValidator.validateHost(host), "Expected error for host: \(host)")
        }
    }

    func testHostRejectsOverLength() {
        // RFC 1035 caps a domain at 253 — one char more must fail.
        let maxHost = String(repeating: "a", count: 249) + ".com" // 253
        XCTAssertNoThrow(try ProfileValidator.validateHost(maxHost))
        let tooLong = String(repeating: "a", count: 250) + ".com" // 254
        XCTAssertThrowsError(try ProfileValidator.validateHost(tooLong))
    }

    // MARK: - Username Validation Tests

    func testValidUsernames() throws {
        XCTAssertEqual(try ProfileValidator.validateUsername("root"), "root")
        XCTAssertEqual(try ProfileValidator.validateUsername("ubuntu"), "ubuntu")
        XCTAssertEqual(try ProfileValidator.validateUsername("admin_vpn"), "admin_vpn")
        XCTAssertEqual(try ProfileValidator.validateUsername("user-01"), "user-01")
    }

    func testEmptyAndGarbageUsername() {
        XCTAssertThrowsError(try ProfileValidator.validateUsername("")) { error in
            XCTAssertEqual(error as? ProfileValidationError, .emptyUsername)
        }
        XCTAssertThrowsError(try ProfileValidator.validateUsername("   ")) { error in
            XCTAssertEqual(error as? ProfileValidationError, .emptyUsername)
        }
        XCTAssertThrowsError(try ProfileValidator.validateUsername("user:name"))
        XCTAssertThrowsError(try ProfileValidator.validateUsername("user\nroot"))
    }

    func testUsernameRejectsInvisibleAndSpoofingScalars() {
        let spoofedUsernames = [
            "ro\u{200B}ot",            // zero-width space (middle — edge-ZWSP
                                       // is trimmed as whitespace first)
            "\u{202E}root",            // bidi RLO — classic spoof
            "ro\u{FEFF}ot",            // BOM
            "ro\u{00AD}ot",            // soft hyphen
            "ro\u{E000}ot",            // private use
            "ro\u{FFFE}ot"             // noncharacter
        ]
        for username in spoofedUsernames {
            XCTAssertThrowsError(try ProfileValidator.validateUsername(username), "Expected error for: \(username)")
        }
    }

    func testUsernameRejectsOverLength() {
        XCTAssertNoThrow(try ProfileValidator.validateUsername(String(repeating: "u", count: 32)))
        XCTAssertThrowsError(try ProfileValidator.validateUsername(String(repeating: "u", count: 33)))
    }

    // MARK: - Credentials Validation

    func testCredentialsValidation() throws {
        // Missing both
        XCTAssertThrowsError(try ProfileValidator.validateCredentials(password: "", privateKey: "")) { error in
            XCTAssertEqual(error as? ProfileValidationError, .missingAuthentication)
        }
        // Valid password
        XCTAssertNoThrow(try ProfileValidator.validateCredentials(password: "secret123", privateKey: ""))
        // Garbage private key
        XCTAssertThrowsError(try ProfileValidator.validateCredentials(password: "", privateKey: "this is totally not a key")) { error in
            XCTAssertEqual(error as? ProfileValidationError, .invalidPrivateKeyFormat)
        }
    }

    // MARK: - Pinned Host Key Validation

    private let ed25519HostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAbchmYXx9J5NlGjxSTzFs3xKH1VoTGInEXBmWrIT56Q user@vps"

    func testHostKeyEmptyMeansTOFU() throws {
        XCTAssertEqual(try ProfileValidator.validateHostKey(""), "")
        XCTAssertEqual(try ProfileValidator.validateHostKey("   \n  "), "")
    }

    func testHostKeyValidEd25519Line() throws {
        XCTAssertEqual(try ProfileValidator.validateHostKey(ed25519HostKey), ed25519HostKey)
        // Whitespace-only cleanup
        XCTAssertEqual(
            try ProfileValidator.validateHostKey("  \(ed25519HostKey)  "),
            ed25519HostKey)
    }

    func testHostKeyWithoutCommentStillValid() throws {
        let noComment = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDTest123 root@server"
        XCTAssertNoThrow(try ProfileValidator.validateHostKey(noComment))
    }

    func testHostKeyRejectsFingerprint() {
        // SHA256 fingerprint — the classic wrong paste
        XCTAssertThrowsError(try ProfileValidator.validateHostKey("SHA256:4Ws4GKNi5t5J5Q8mFqy1ZKtZv0qA9cO7fWtmuUpLmZc")) { error in
            guard case .invalidHostKey(.expectedFormat)? = error as? ProfileValidationError else {
                XCTFail("Expected invalidHostKey(.expectedFormat), got \(error)")
                return
            }
        }
    }

    func testHostKeyRejectsPrivateKeyPem() {
        let pem = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----"
        XCTAssertThrowsError(try ProfileValidator.validateHostKey(pem))
    }

    func testHostKeyRejectsMultiLinePaste() {
        let twoKeys = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABgQDTest1 root@a\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAATest2 root@b"
        XCTAssertThrowsError(try ProfileValidator.validateHostKey(twoKeys))
    }

    func testHostKeyRejectsBadBase64() {
        XCTAssertThrowsError(try ProfileValidator.validateHostKey("ssh-ed25519 NOT-BASE64!!! user@vps"))
    }

    func testHostKeyRejectsInvisibleScalars() {
        XCTAssertThrowsError(try ProfileValidator.validateHostKey("ssh-ed25519\u{200B} AAAAC3NzaC1lZDI1NTE5AAAATest user@vps"))
    }

    func testHostKeyRejectsGarbage() {
        for input in ["hello", "ssh-ed25519", "just some words here", "2048 SHA256:abc /root/.ssh/id_ed25519 (ED25519)"] {
            XCTAssertThrowsError(try ProfileValidator.validateHostKey(input), "Expected error for: \(input)")
        }
    }
}
