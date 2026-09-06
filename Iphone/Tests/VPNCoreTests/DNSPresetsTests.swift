import XCTest
@testable import VPNCore

final class DNSPresetsTests: XCTestCase {

    func testEveryPresetUsesValidIPv4Literals() {
        // A preset with a typo'd IP would silently blackhole DNS for anyone
        // who taps it — validate the catalog itself.
        for preset in DNSPresets.all {
            XCTAssertTrue(AppSettingsState.isValidIPv4Literal(preset.primary),
                          "\(preset.name) primary \(preset.primary) is not a valid IPv4 literal")
            XCTAssertTrue(AppSettingsState.isValidIPv4Literal(preset.secondary),
                          "\(preset.name) secondary \(preset.secondary) is not a valid IPv4 literal")
        }
    }

    func testPresetIPIsUniqueWithinPreset() {
        for preset in DNSPresets.all {
            XCTAssertNotEqual(preset.primary, preset.secondary, "\(preset.name) primary == secondary")
        }
    }

    func testNoDuplicatePresetIPPairs() {
        var seen = Set<String>()
        for preset in DNSPresets.all {
            let key = "\(preset.primary)|\(preset.secondary)"
            XCTAssertTrue(seen.insert(key).inserted, "duplicate preset pair: \(preset.name)")
        }
    }

    func testMatchesIgnoresWhitespace() {
        let preset = DNSPresets.all[0]
        XCTAssertTrue(preset.matches(primary: " \(preset.primary) ", secondary: "\(preset.secondary)\t"))
        XCTAssertFalse(preset.matches(primary: preset.primary, secondary: "9.9.9.9"))
    }

    func testFilterCoverageForTheCatalog() {
        // The point of the list: a real choice at every strictness level.
        let filters = Set(DNSPresets.all.map(\.filter))
        XCTAssertTrue(filters.contains(.none))
        XCTAssertTrue(filters.contains(.malware))
        XCTAssertTrue(filters.contains(.ads))
        XCTAssertTrue(filters.contains(.family))
    }

    func testEveryPresetHasBothDescriptions() {
        // The UI shows exactly one of these — empty text would render a
        // broken row.
        for preset in DNSPresets.all {
            XCTAssertFalse(preset.descriptionEN.isEmpty, "\(preset.name) has no EN description")
            XCTAssertFalse(preset.descriptionRU.isEmpty, "\(preset.name) has no RU description")
        }
    }

    func testPresetsGroupedByFilterStayQueryable() {
        for filter in DNSPreset.Filter.allCases {
            let group = DNSPresets.presets(matching: filter)
            XCTAssertFalse(group.isEmpty, "group \(filter.rawValue) must not be empty")
            XCTAssertTrue(group.allSatisfy { $0.filter == filter })
        }
    }

    func testDescriptionLocalizationSwitch() {
        let preset = DNSPresets.all[0]
        XCTAssertEqual(preset.description(forRussian: true), preset.descriptionRU)
        XCTAssertEqual(preset.description(forRussian: false), preset.descriptionEN)
    }
}
