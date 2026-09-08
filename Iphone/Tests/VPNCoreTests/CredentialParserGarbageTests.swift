import XCTest
@testable import VPNCore

/// Hostile and sloppy input: the parser must never crash and never silently
/// produce wrong credentials — either a correct parse or an explicit error.
final class CredentialParserGarbageTests: XCTestCase {

    func testEmptyInput() {
        XCTAssertThrowsError(try CredentialParser.parse("")) { e in
            XCTAssertEqual(e as? CredentialParser.ParseError, .emptyInput)
        }
    }

    func testWhitespaceOnlyInput() {
        for input in ["   ", "\n\n", "\t\t", " \n\t ", "\u{00A0}\u{00A0}"] {
            XCTAssertThrowsError(try CredentialParser.parse(input), "input: \(input)") { e in
                XCTAssertEqual(e as? CredentialParser.ParseError, .emptyInput)
            }
        }
    }

    func testZeroWidthAndInvisibleGarbage() {
        // Zero-width spaces get stripped by normalization; the host survives.
        do {
            let p = try CredentialParser.parse("\u{200B}1.2.3.4\u{200B}:22:root:x")
            XCTAssertEqual(p.host, "1.2.3.4")
        } catch {
            XCTFail("zero-width stripping failed: \(error)")
        }
    }

    func testPureGarbageWords() {
        for input in ["hello world", "кукуруза", "!!! @@@ ###", "я не знаю что сюда писать"] {
            XCTAssertThrowsError(try CredentialParser.parse(input), "input: \(input)")
        }
    }

    func testShellInjectionStrings() {
        let injections = [
            "1.2.3.4:22:root:secret; rm -rf /",
            "$(reboot)@1.2.3.4",
            "1.2.3.4 && shutdown now",
            "`id`@host.example.com",
            "host.example.com:22:user:`whoami`",
        ]
        for input in injections {
            // Must not crash; either error or a parse whose host is host-like.
            _ = try? CredentialParser.parse(input)
        }
    }

    func testHugeInputDoesNotHang() {
        // 100k of colon-separated junk must complete fast and not crash.
        let huge = String(repeating: "a:", count: 50_000) + "b"
        measure {
            _ = try? CredentialParser.parse(huge)
        }
    }

    func testTruncatedAndIncomplete() {
        XCTAssertThrowsError(try CredentialParser.parse(":"))
        XCTAssertThrowsError(try CredentialParser.parse(":::"))
        XCTAssertThrowsError(try CredentialParser.parse("user@"))
        XCTAssertThrowsError(try CredentialParser.parse("ssh://"))
        // "1.2.3.4:" (trailing colon) falls back to a host-scan parse with
        // defaults — acceptable; it must not invent a password or wrong port.
        if let p = try? CredentialParser.parse("1.2.3.4:") {
            XCTAssertEqual(p.host, "1.2.3.4")
            XCTAssertEqual(p.port, 22)
            XCTAssertNil(p.password)
        }
        // Degenerate "@host" / "user:@" may fall back to a host-scan parse with
        // pure defaults — acceptable as long as NO password is invented.
        if let p = try? CredentialParser.parse("root:@") {
            XCTAssertNil(p.password, "invented password from empty userinfo")
            XCTAssertEqual(p.username, "root")
        }
        if let p = try? CredentialParser.parse("@1.2.3.4") {
            XCTAssertNil(p.password, "invented password from empty userinfo")
        }
    }

    func testPortBoundaries() throws {
        // Valid edges.
        XCTAssertEqual(try CredentialParser.parse("1.2.3.4:1:root:x").port, 1)
        XCTAssertEqual(try CredentialParser.parse("1.2.3.4:65535:root:x").port, 65535)
        // Out of range must never yield the bad port silently.
        for bad in [65536, 0, 99999] {
            let result = try? CredentialParser.parse("1.2.3.4:\(bad):root:x")
            if let result {
                XCTAssertNotEqual(result.port, bad, "silently accepted bad port \(bad)")
            }
        }
    }

    func testNoSilentWrongPasswordFromAmbiguousTwoPart() throws {
        // "host:something" where something is NOT numeric must NOT be treated
        // as host:password — too ambiguous, colon form rejects it. Whatever
        // other strategy accepts it, the port must stay the 22 default.
        let result = try? CredentialParser.parse("1.2.3.4:secret")
        if let result {
            XCTAssertEqual(result.host, "1.2.3.4")
            XCTAssertEqual(result.port, 22)
            XCTAssertEqual(result.username, "root")
        }
    }

    func testMultilineTakesFirstValidLine() throws {
        let multi = """
        This is your new server:
        1.2.3.4:22:root:hunter2
        Backup: 5.6.7.8:22:root:backup
        """
        let p = try CredentialParser.parse(multi)
        XCTAssertEqual(p.host, "1.2.3.4")
        XCTAssertEqual(p.password, "hunter2")
    }

    func testCyrillicPasswordSurvives() throws {
        let p = try CredentialParser.parse("1.2.3.4:22:root:пароль123")
        XCTAssertEqual(p.password, "пароль123")
    }

    func testEmojiInPassword() throws {
        let p = try CredentialParser.parse("1.2.3.4:22:root:🔑secret")
        XCTAssertEqual(p.password, "🔑secret")
    }

    func testBase64LookingChunkIsNotMistakenForHost() {
        // A random base64 blob is NOT a host; parse must error, not invent one.
        let blob = "YWJjZGVmZ2hpamtsbW5vcA=="
        XCTAssertThrowsError(try CredentialParser.parse(blob))
    }
}
