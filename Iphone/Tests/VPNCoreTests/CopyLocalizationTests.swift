import XCTest
@testable import VPNCore

/// Source-integrity checks for App/Copy.swift localization: every CopyKey
/// case declared in the enum must appear in EVERY one of the 18 language
/// dictionaries. A missing key silently falls back to English and ships a
/// half-localized screen — this makes that impossible to miss.
final class CopyLocalizationTests: XCTestCase {
    private static let copyPath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // Tests/VPNCoreTests
        .deletingLastPathComponent()      // Tests
        .deletingLastPathComponent()      // Iphone
        .appendingPathComponent("App/Copy.swift")

    private lazy var source: String = {
        guard let text = try? String(contentsOf: Self.copyPath, encoding: .utf8) else {
            XCTFail("Copy.swift not found at \(Self.copyPath.path)")
            return ""
        }
        return text
    }()

    /// All case names declared in the CopyKey enum (only `case` lines count).
    private lazy var allKeys: [String] = {
        guard let range = source.range(of: "enum CopyKey {") else { return [] }
        guard let end = source.range(of: "\n}", range: range.upperBound..<source.endIndex) else { return [] }
        let body = String(source[range.upperBound..<end.lowerBound])
        var names: [String] = []
        // Cases are declared as `case a, b, c` or `case a` — split each case
        // line on commas and take the identifier tokens.
        for line in body.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("case ") else { continue }
            let namesPart = trimmed.dropFirst("case ".count)
            for token in namesPart.split(separator: ",") {
                let name = token.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0 == "_" }) else { continue }
                names.append(name)
            }
        }
        return names
    }()

    private static let languageDictionaries = [
        "english", "russian", "spanish", "german", "japanese", "chinese",
        "french", "italian", "portuguese", "korean", "arabic", "hindi",
        "thai", "turkish", "polish", "dutch", "vietnamese",
    ]

    func testKeysParsedFromEnum() {
        XCTAssertFalse(allKeys.isEmpty, "failed to parse CopyKey cases")
        XCTAssertTrue(allKeys.contains("keyImportFromFile"))
        XCTAssertTrue(allKeys.contains("dnsListsTitle"))
    }

    func testEveryKeyInEveryLanguageDictionary() {
        let keys = Set(allKeys)
        XCTAssertFalse(keys.isEmpty)
        for lang in Self.languageDictionaries {
            guard let start = source.range(of: "private let \(lang): [CopyKey: String] = [") else {
                XCTFail("dictionary \(lang) not found")
                continue
            }
            guard let end = source.range(of: "\n    ]", range: start.upperBound..<source.endIndex) else {
                XCTFail("closing bracket for \(lang) not found")
                continue
            }
            let block = source[start.upperBound..<end.lowerBound]
            let missing = keys.filter { !block.contains(".\($0):") }
                .sorted()
            XCTAssertTrue(missing.isEmpty,
                          "\(lang) is missing translations for: \(missing.joined(separator: ", "))")
        }
    }

    /// The newly added feature block must exist in every dictionary (the
    /// insertion script writes all of them at once — a partial run must fail).
    func testNewFeatureKeysPresentInAllDictionaries() {
        for lang in Self.languageDictionaries {
            guard let start = source.range(of: "private let \(lang): [CopyKey: String] = ["),
                  let end = source.range(of: "\n    ]", range: start.upperBound..<source.endIndex) else {
                XCTFail("dictionary \(lang) not found"); continue
            }
            let block = String(source[start.upperBound..<end.lowerBound])
            for probe in ["keyImportFromFile", "dnsTabCustom", "dnsListsTitle", "dnsListInfoBody", "dnsListsActiveCount", "yes",
                          "hostKeyErrTitle", "hostKeyErrMultiLine", "hostKeyErrInvisible",
                          "hostKeyErrExpectedFormat", "hostKeyErrUnknownType", "hostKeyErrBadBase64"] {
                XCTAssertTrue(block.contains(".\(probe):"), "\(lang) missing .\(probe)")
            }
        }
    }
}
