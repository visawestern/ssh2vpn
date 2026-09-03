import XCTest
@testable import VPNCore

/// Tests ingesting extension-side log entries into the app's store: original
/// timestamps must survive (diagnosis needs true ordering), repeats from
/// overlapping poll windows must not duplicate, and the cap must hold.
final class ConsoleLogIngestTests: XCTestCase {

    func testIngestPreservesOriginalTimestamps() {
        let store = ConsoleLogStore()
        store.clear()
        let ext = ConsoleLogEntry(level: .info, tag: "TUNNEL", message: "from extension",
                                  formattedTimestamp: "10:00:00.001")
        store.ingestExternal([ext])

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].formattedTimestamp, "10:00:00.001")
        XCTAssertTrue(store.exportPlainText().contains("from extension"))
    }

    func testIngestDedupesByID() {
        let store = ConsoleLogStore()
        store.clear()
        let ext = ConsoleLogEntry(level: .info, tag: "TUNNEL", message: "once")
        store.ingestExternal([ext])
        store.ingestExternal([ext])

        XCTAssertEqual(store.entries.count, 1)
    }

    func testIngestKeepsLocalAndExternalTogether() {
        let store = ConsoleLogStore()
        store.clear()
        store.log(level: .info, tag: "APP", message: "local line")
        store.ingestExternal([ConsoleLogEntry(level: .info, tag: "TUNNEL", message: "ext line")])

        XCTAssertEqual(store.entries.count, 2)
        let export = store.exportPlainText()
        XCTAssertTrue(export.contains("local line"))
        XCTAssertTrue(export.contains("ext line"))
    }

    func testIngestRespectsMaxEntries() {
        let store = ConsoleLogStore(maxEntries: 3)
        store.clear()
        let batch = (0..<5).map { ConsoleLogEntry(level: .info, tag: "T", message: "m\($0)") }
        store.ingestExternal(batch)

        XCTAssertEqual(store.entries.count, 3)
    }

    func testIngestPostsAppendNotification() {
        let store = ConsoleLogStore()
        store.clear()
        let exp = expectation(forNotification: .consoleLogDidAppend, object: nil, handler: nil)
        store.ingestExternal([ConsoleLogEntry(level: .info, tag: "T", message: "ping")])
        wait(for: [exp], timeout: 2)
    }
}
