import XCTest
@testable import VPNCore

/// Tests the `logs` command: the extension exposes its in-memory console lines
/// so the app can pull real tunnel diagnostics over the message channel (the
/// only bridge that works without an app-group). Entries are pre-sanitized at
/// log() time, so no secrets can leak through here.
final class TunnelRouterLogsTests: XCTestCase {

    private func makeStore() -> TunnelServerStore {
        TunnelServerStore(defaults: UserDefaults(suiteName: "test.router-logs.\(UUID().uuidString)")!)
    }

    private func makeRouter(logs: [ConsoleLogEntry]) -> TunnelAppMessageRouter {
        TunnelAppMessageRouter(
            serverStore: makeStore(),
            statusProvider: { [:] },
            errorProvider: { [:] },
            logProvider: { logs }
        )
    }

    private func sampleEntry(_ message: String) -> ConsoleLogEntry {
        ConsoleLogEntry(level: .info, tag: "TUNNEL", message: message)
    }

    private func decodeEntries(_ data: Data?) -> [ConsoleLogEntry]? {
        guard let data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = obj["data"] as? [String: String],
              let json = payload["entries"],
              let raw = Data(json.utf8) as Data?,
              let arr = try? JSONDecoder().decode([ConsoleLogEntry].self, from: raw) else {
            return nil
        }
        return arr
    }

    private func request(cmd: String, args: [String: Any]? = nil) -> Data {
        var body: [String: Any] = ["cmd": cmd]
        if let args { body["args"] = args }
        return try! JSONSerialization.data(withJSONObject: body)
    }

    func testLogsReturnsEmptyArrayWhenStoreEmpty() {
        let entries = decodeEntries(makeRouter(logs: []).handle(request(cmd: "logs")))
        XCTAssertNotNil(entries)
        XCTAssertTrue(entries!.isEmpty)
    }

    func testLogsReturnsEntriesWithMessages() {
        let router = makeRouter(logs: [sampleEntry("hello"), sampleEntry("world")])
        let entries = decodeEntries(router.handle(request(cmd: "logs")))!
        XCTAssertEqual(entries.map(\.message), ["hello", "world"])
        XCTAssertEqual(entries.map(\.tag), ["TUNNEL", "TUNNEL"])
    }

    func testLogsRespectsLimit() {
        let logs = (0..<5).map { sampleEntry("m\($0)") }
        let router = makeRouter(logs: logs)
        let entries = decodeEntries(router.handle(request(cmd: "logs", args: ["limit": 2])))!
        XCTAssertEqual(entries.count, 2)
        // Newest last: the tail of the window is returned.
        XCTAssertEqual(entries.map(\.message), ["m3", "m4"])
    }

    func testLogsEntryCodecRoundTrip() {
        let original = ConsoleLogEntry(level: .error, tag: "SESSION", message: "boom")
        let data = try! JSONEncoder().encode([original])
        let decoded = try! JSONDecoder().decode([ConsoleLogEntry].self, from: data)
        XCTAssertEqual(decoded, [original])
    }
}
