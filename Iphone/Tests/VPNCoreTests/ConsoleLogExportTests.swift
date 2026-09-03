import XCTest
@testable import VPNCore

/// Regression tests for the share/export mismatch: the console screen shows
/// the current session only, so COPY/SHARE must export exactly that — never
/// stale history persisted by previous launches (which also leaks log strings
/// from older builds into fresh diagnostics).
final class ConsoleLogExportTests: XCTestCase {

    private let legacyKey = "console.log.entries.v1"

    private var defaults: UserDefaults {
        UserDefaults(suiteName: "group.com.sshtunnel.shared") ?? .standard
    }

    override func setUp() {
        super.setUp()
        defaults.removeObject(forKey: legacyKey)
    }

    override func tearDown() {
        defaults.removeObject(forKey: legacyKey)
        super.tearDown()
    }

    /// Seeds history in the legacy persisted format (as older builds wrote it).
    private func seedLegacyHistory(message: String = "STALE FROM OLD BUILD") {
        defaults.set([["t": "00:00:00.000", "l": "INFO", "g": "OLD", "m": message]], forKey: legacyKey)
    }

    func testExportIgnoresLegacyPersistedHistory() {
        seedLegacyHistory()
        let store = ConsoleLogStore()
        store.clear()
        store.log(level: .info, tag: "FRESH", message: "current session line")

        let export = store.exportPlainText()
        XCTAssertTrue(export.contains("current session line"))
        XCTAssertFalse(export.contains("STALE FROM OLD BUILD"),
                       "Export must contain only what is on screen, never stale persisted history")
    }

    func testExportEntryCountMatchesScreen() {
        seedLegacyHistory()
        let store = ConsoleLogStore()
        store.clear()
        store.log(level: .info, tag: "A", message: "one")
        store.log(level: .info, tag: "B", message: "two")

        XCTAssertEqual(store.entries.count, 2)
        let export = store.exportPlainText()
        XCTAssertTrue(export.contains("Entries: 2"),
                      "Exported count must match the on-screen entry count")
    }

    func testClearWipesLegacyPersistedHistoryToo() {
        seedLegacyHistory()
        let store = ConsoleLogStore()
        store.clear()

        XCTAssertNil(defaults.array(forKey: legacyKey),
                     "CLEAR must wipe persisted history as well, or the next share resurrects it")
        XCTAssertFalse(store.exportPlainText().contains("STALE FROM OLD BUILD"))
    }
}
