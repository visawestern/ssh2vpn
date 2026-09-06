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

    func testChipCoverageForTheCatalog() {
        // The point of the chips: every blocking dimension is represented,
        // and family presets genuinely carry more than just "adult".
        let allChips = Set(DNSPresets.all.flatMap(\.chips))
        for chip in DNSPreset.Chip.allCases {
            XCTAssertTrue(allChips.contains(chip), "chip \(chip.rawValue) never used")
        }
        // AdGuard Family blocks adult + ads + trackers + malware + safe search.
        let adGuardFamily = DNSPresets.all.first { $0.id == "adguard-family" }!
        XCTAssertEqual(Set(adGuardFamily.chips),
                       Set([.adult, .ads, .trackers, .malware, .safeSearch]))
        // Plain AdGuard blocks ads + trackers + malware (not adult).
        let adGuard = DNSPresets.all.first { $0.id == "adguard" }!
        XCTAssertEqual(Set(adGuard.chips), Set([.ads, .trackers, .malware]))
    }

    func testNoFilterPresetsCarryNoBlockingChips() {
        for preset in DNSPresets.all where preset.chips.contains(.noFilter) {
            let blocking = preset.chips.filter { $0 != .noFilter && $0 != .privacy }
            XCTAssertTrue(blocking.isEmpty, "\(preset.name) claims NO FILTER but blocks \(blocking)")
        }
    }
}
