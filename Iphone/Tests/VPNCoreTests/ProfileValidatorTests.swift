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
}
