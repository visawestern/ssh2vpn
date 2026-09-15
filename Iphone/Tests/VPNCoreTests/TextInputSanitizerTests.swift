import XCTest
@testable import VPNCore

final class TextInputSanitizerTests: XCTestCase {

    // MARK: - Stripping invisible / spoofing characters

    func testStripsZeroWidthAndBidiGarbage() {
        XCTAssertEqual(TextInputSanitizer.sanitizeLabel("My\u{200B}Server"), "MyServer")
        XCTAssertEqual(TextInputSanitizer.sanitizeLabel("My\u{2060}Server"), "MyServer")
        XCTAssertEqual(TextInputSanitizer.sanitizeLabel("Ser\u{00AD}ver"), "Server")
        XCTAssertEqual(TextInputSanitizer.sanitizeLabel("\u{202A}evil\u{202C}"), "evil")
        XCTAssertEqual(TextInputSanitizer.sanitizeLabel("\u{2067}user\u{2069}"), "user")
        XCTAssertEqual(TextInputSanitizer.sanitizeLabel("\u{FEFF}Server"), "Server")
    }

    func testStripsControlCharacters() {
        XCTAssertEqual(TextInputSanitizer.sanitizeLabel("Ser\u{07}ver"), "Server")
        XCTAssertEqual(TextInputSanitizer.sanitizeLabel("a\u{01}b\u{02}c"), "abc")
        // Tab / newline are control category; whitespace keeps semantic use.
        XCTAssertEqual(TextInputSanitizer.sanitizeLabel("row1\trow2"), "row1 row2")
        XCTAssertEqual(TextInputSanitizer.sanitizeLabel("row1\nrow2"), "row1 row2")
    }

    func testStripsPrivateUseAndNoncharacters() {
        XCTAssertEqual(TextInputSanitizer.sanitizeLabel("My\u{E000}Server"), "MyServer")
        XCTAssertEqual(TextInputSanitizer.sanitizeLabel("My\u{FFFE}Server"), "MyServer")
    }

    // MARK: - Whitespace normalization

    func testCollapsesExoticWhitespaceToSingleAsciiSpace() {
        XCTAssertEqual(TextInputSanitizer.sanitizeLabel("My\u{00A0}Server"), "My Server")
        XCTAssertEqual(TextInputSanitizer.sanitizeLabel("My\u{3000}Server"), "My Server")
        XCTAssertEqual(TextInputSanitizer.sanitizeLabel("My    Server"), "My Server")
        XCTAssertEqual(TextInputSanitizer.sanitizeLabel("My\t\t\tServer"), "My Server")
    }

    func testTrimsLeadingAndTrailingWhitespace() {
        XCTAssertEqual(TextInputSanitizer.sanitizeLabel("   Server   "), "Server")
        XCTAssertEqual(TextInputSanitizer.sanitizeLabel(" \u{00A0}x \t"), "x")
    }

    // MARK: - Length caps

    func testCapsLengthByGraphemeCluster() {
        let long = String(repeating: "ab", count: 30) // 60 clusters
        XCTAssertEqual(TextInputSanitizer.sanitizeLabel(long)?.count, TextInputSanitizer.labelMaxLength)

        // A flag emoji is one grapheme cluster — the cut never splits it.
        let flag = "\u{1F1FA}\u{1F1F8}" // US flag
        let cappedFlags = TextInputSanitizer.sanitizeLabel(String(repeating: flag, count: 50))
        XCTAssertEqual(cappedFlags?.count, TextInputSanitizer.labelMaxLength)
        XCTAssertEqual(cappedFlags, String(repeating: flag, count: TextInputSanitizer.labelMaxLength))
    }

    func testCappedHelperIsGraphemeSafe() {
        let flag = "\u{1F1FA}\u{1F1F8}"
        let capped = TextInputSanitizer.capped(String(repeating: flag, count: 50), maxLength: 3)
        XCTAssertEqual(capped, String(repeating: flag, count: 3))
    }

    // MARK: - Zalgo / combining-mark towers

    func testClipsZalgoTowers() {
        // 20 stacked combining marks after "e" — only maxCombiningRun survive.
        let zalgo = "e" + String(repeating: "\u{0301}", count: 20)
        let sanitized = TextInputSanitizer.sanitizeLabel(zalgo)!
        XCTAssertEqual(sanitized.unicodeScalars.count, 1 + TextInputSanitizer.maxCombiningRun)
        XCTAssertEqual(sanitized, "e" + String(repeating: "\u{0301}", count: TextInputSanitizer.maxCombiningRun))

        // The run counter resets after a normal base character.
        let tower = "e" + String(repeating: "\u{0301}", count: 10) + "a" + String(repeating: "\u{0302}", count: 10)
        let result = TextInputSanitizer.sanitizeLabel(tower)!
        XCTAssertTrue(result.hasPrefix("e" + String(repeating: "\u{0301}", count: TextInputSanitizer.maxCombiningRun)))
        XCTAssertTrue(result.hasSuffix("a" + String(repeating: "\u{0302}", count: TextInputSanitizer.maxCombiningRun)))
    }

    func testKeepsLegitimateCombiningScriptText() {
        XCTAssertEqual(TextInputSanitizer.sanitizeLabel("Мой сервер"), "Мой сервер")
        // Devanagari cluster (ka + virama + ka + vowel sign) survives.
        let hindi = "\u{0915}\u{094D}\u{0915}\u{0940}"
        XCTAssertEqual(TextInputSanitizer.sanitizeLabel(hindi), String(hindi))
        // Vietnamese with tone marks survives.
        XCTAssertEqual(TextInputSanitizer.sanitizeLabel("Thủ Đô"), "Thủ Đô")
    }

    // MARK: - Empty / nil semantics

    func testEmptyAndAllGarbageBecomesNil() {
        XCTAssertNil(TextInputSanitizer.sanitizeLabel(nil))
        XCTAssertNil(TextInputSanitizer.sanitizeLabel(""))
        XCTAssertNil(TextInputSanitizer.sanitizeLabel("   "))
        XCTAssertNil(TextInputSanitizer.sanitizeLabel("\u{200B}\u{200B}"))
        XCTAssertNil(TextInputSanitizer.sanitizeLabel("\u{FEFF}\u{00A0}"))
    }

    // MARK: - Identifier scalar check (used by ProfileValidator)

    func testIsUnsafeScalar() {
        XCTAssertTrue(TextInputSanitizer.isUnsafeScalar("\u{200B}"))    // zero-width space
        XCTAssertTrue(TextInputSanitizer.isUnsafeScalar("\u{202E}"))    // bidi RLO
        XCTAssertTrue(TextInputSanitizer.isUnsafeScalar("\u{07}"))      // control
        XCTAssertTrue(TextInputSanitizer.isUnsafeScalar("\u{E000}"))    // private use
        XCTAssertTrue(TextInputSanitizer.isUnsafeScalar("\u{FFFE}"))    // noncharacter
        XCTAssertFalse(TextInputSanitizer.isUnsafeScalar("a"))
        XCTAssertFalse(TextInputSanitizer.isUnsafeScalar("Ж"))
        XCTAssertFalse(TextInputSanitizer.isUnsafeScalar("—"))
        XCTAssertFalse(TextInputSanitizer.isUnsafeScalar("\u{1F1FA}")) // flag half
    }

    // MARK: - Integration through ServerProfile

    func testServerProfileSanitizesLabelOnInitAndDecode() throws {
        let profile = ServerProfile(
            id: "1", name: "h", host: "h", port: 22, username: "root",
            hostKey: "", dnsServers: [],
            hasPassword: false, hasPrivateKey: false,
            label: "  My\u{202E}evil\u{202C}\u{200B}server  "
        )
        // Bidi overrides + zero-width stripped, edges trimmed.
        XCTAssertEqual(profile.label, "Myevilserver")
        XCTAssertNil(ServerProfile.normalizedLabel("\u{200B} \u{FEFF}"))

        // Decode path: garbage stored by an older build is cleaned at load.
        let json = #"{"id":"1","name":"h","host":"h","port":22,"username":"root","hostKey":"","dnsServers":[],"hasPassword":false,"hasPrivateKey":false,"label":"old"}"#
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ServerProfile.self, from: data)
        XCTAssertEqual(decoded.label, "old")
    }
}
