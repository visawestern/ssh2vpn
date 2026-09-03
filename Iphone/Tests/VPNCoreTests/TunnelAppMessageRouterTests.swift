import XCTest
@testable import VPNCore

/// Tests the pure command router that lives in the extension. The router
/// dispatches JSON requests and returns JSON responses. The critical guarantee
/// is that `serverList` / `serverGet` NEVER return secrets — only presence
/// flags. These tests exercise the full command surface against an isolated
/// store so they never touch real storage.
final class TunnelAppMessageRouterTests: XCTestCase {

    private func makeStore() -> (TunnelServerStore, UserDefaults) {
        let suite = "test.router-store.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (TunnelServerStore(defaults: defaults), defaults)
    }

    private func sample(id: String = "aaa", host: String = "1.2.3.4", password: String? = "secret", privateKey: String? = nil) -> ServerProfile {
        ServerProfile(
            id: id, name: "Test", host: host, port: 22, username: "root",
            hostKey: "AAAAB3", dnsServers: ["8.8.8.8"],
            hasPassword: password != nil, hasPrivateKey: privateKey != nil,
            password: password, privateKey: privateKey
        )
    }

    private func makeRouter(store: TunnelServerStore) -> TunnelAppMessageRouter {
        TunnelAppMessageRouter(
            serverStore: store,
            statusProvider: { ["phase": "begin", "transport": "nil"] },
            errorProvider: { ["error": "none"] }
        )
    }

    private func encode(_ value: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: value)
    }

    private func decode(_ data: Data?) -> [String: Any]? {
        guard let data else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func responseData(_ router: TunnelAppMessageRouter, cmd: String, args: [String: Any]? = nil) -> [String: Any]? {
        var body: [String: Any] = ["cmd": cmd]
        if let args { body["args"] = args }
        return decode(router.handle(encode(body)))
    }

    // MARK: - status / lastError

    func testStatusReturnsPhaseAndTransport() {
        let (store, _) = makeStore()
        let r = responseData(makeRouter(store: store), cmd: "status")!
        XCTAssertEqual(r["ok"] as? Bool, true)
        let data = r["data"] as? [String: String]
        XCTAssertEqual(data?["phase"], "begin")
        XCTAssertEqual(data?["transport"], "nil")
    }

    func testLastErrorReturnsStoredError() {
        let (store, _) = makeStore()
        let router = TunnelAppMessageRouter(
            serverStore: store,
            statusProvider: { [:] },
            errorProvider: { ["error": "auth failed"] }
        )
        let r = responseData(router, cmd: "lastError")!
        let data = r["data"] as? [String: String]
        XCTAssertEqual(data?["error"], "auth failed")
    }

    // MARK: - serverList

    func testServerListReturnsAllWithoutSecrets() {
        let (store, _) = makeStore()
        store.save(sample(id: "1", password: "p", privateKey: "k"))
        store.save(sample(id: "2", host: "2.2.2.2", password: nil, privateKey: nil))

        let r = responseData(makeRouter(store: store), cmd: "serverList")!
        XCTAssertEqual(r["ok"] as? Bool, true)
        let data = r["data"] as? [String: String]

        // Servers are returned as a JSON string under "servers".
        guard let json = data?["servers"],
              let servers = try? JSONDecoder().decode([ServerProfile].self, from: Data(json.utf8)) else {
            XCTFail("servers must be a JSON array of ServerProfile")
            return
        }
        XCTAssertEqual(servers.count, 2)

        // CRITICAL: no secret values leak.
        for s in servers {
            XCTAssertNil(s.password, "password must never be returned to the app")
            XCTAssertNil(s.privateKey, "privateKey must never be returned to the app")
        }

        // But presence flags DO reflect what is stored.
        let s1 = servers.first { $0.id == "1" }!
        XCTAssertTrue(s1.hasPassword)
        XCTAssertTrue(s1.hasPrivateKey)
        let s2 = servers.first { $0.id == "2" }!
        XCTAssertFalse(s2.hasPassword)
        XCTAssertFalse(s2.hasPrivateKey)
    }

    func testServerListReturnsSelectedID() {
        let (store, _) = makeStore()
        store.save(sample(id: "1"))
        store.save(sample(id: "2"))
        store.select(id: "2")

        let r = responseData(makeRouter(store: store), cmd: "serverList")!
        let data = r["data"] as? [String: String]
        XCTAssertEqual(data?["selectedID"], "2")
    }

    func testServerListEmptyWhenNothingStored() {
        let (store, _) = makeStore()
        let r = responseData(makeRouter(store: store), cmd: "serverList")!
        let data = r["data"] as? [String: String]
        let servers = try! JSONDecoder().decode([ServerProfile].self, from: Data((data?["servers"] ?? "[]").utf8))
        XCTAssertTrue(servers.isEmpty)
    }

    // MARK: - serverGet

    func testServerGetReturnsOneByIdWithoutSecrets() {
        let (store, _) = makeStore()
        store.save(sample(id: "1", password: "secret"))

        let r = responseData(makeRouter(store: store), cmd: "serverGet", args: ["id": "1"])!
        XCTAssertEqual(r["ok"] as? Bool, true)
        let data = r["data"] as? [String: String]

        guard let json = data?["server"],
              let server = try? JSONDecoder().decode(ServerProfile.self, from: Data(json.utf8)) else {
            XCTFail("server must be a JSON ServerProfile")
            return
        }
        XCTAssertEqual(server.id, "1")
        XCTAssertEqual(server.host, "1.2.3.4")
        XCTAssertNil(server.password, "secret must not leak via serverGet")
        XCTAssertTrue(server.hasPassword)
    }

    func testServerGetReturnsErrorForMissingId() {
        let (store, _) = makeStore()
        let r = responseData(makeRouter(store: store), cmd: "serverGet", args: ["id": "ghost"])!
        XCTAssertEqual(r["ok"] as? Bool, false)
        XCTAssertNotNil((r["data"] as? [String: String])?["error"])
    }

    // MARK: - serverSet

    func testServerSetAddsNew() {
        let (store, _) = makeStore()
        let profile = sample(id: "1", host: "1.1.1.1", password: "p")

        let r = responseData(makeRouter(store: store), cmd: "serverSet", args: profile.toJSONDict())!
        XCTAssertEqual(r["ok"] as? Bool, true)
        XCTAssertEqual(store.loadAll().count, 1)
        XCTAssertEqual(store.load(id: "1")?.host, "1.1.1.1")
    }

    func testServerSetStoresSecret() {
        let (store, _) = makeStore()
        let profile = sample(id: "1", password: "sekret", privateKey: "key")
        _ = responseData(makeRouter(store: store), cmd: "serverSet", args: profile.toJSONDict())!

        let loaded = store.load(id: "1")!
        XCTAssertEqual(loaded.password, "sekret")
        XCTAssertEqual(loaded.privateKey, "key")
        XCTAssertTrue(loaded.hasPassword)
        XCTAssertTrue(loaded.hasPrivateKey)
    }

    func testServerSetUpdatesExistingById() {
        let (store, _) = makeStore()
        store.save(sample(id: "1", host: "1.1.1.1"))
        let updated = sample(id: "1", host: "9.9.9.9")
        _ = responseData(makeRouter(store: store), cmd: "serverSet", args: updated.toJSONDict())!

        XCTAssertEqual(store.loadAll().count, 1)
        XCTAssertEqual(store.load(id: "1")?.host, "9.9.9.9")
    }

    /// Editing a server MUST preserve existing secrets when the app omits them
    /// (the app cannot read secrets back, so absent = "don't change").
    func testServerSetPreservesSecretsWhenOmitted() {
        let (store, _) = makeStore()
        let original = sample(id: "1", host: "1.1.1.1", password: "secret", privateKey: "key")
        store.save(original)

        // App sends only non-secret fields (host change) — no password/key keys.
        let partial: [String: Any] = [
            "id": "1", "name": "1.1.1.1", "host": "9.9.9.9", "port": 22,
            "username": "root", "hostKey": "AAAAB3", "dnsServers": ["8.8.8.8"],
            "hasPassword": false, "hasPrivateKey": false
        ]
        let r = responseData(makeRouter(store: store), cmd: "serverSet", args: partial)!
        XCTAssertEqual(r["ok"] as? Bool, true)

        let loaded = store.load(id: "1")!
        XCTAssertEqual(loaded.host, "9.9.9.9", "host should update")
        // CRITICAL: secrets must survive the edit.
        XCTAssertEqual(loaded.password, "secret", "existing password must be preserved when omitted")
        XCTAssertEqual(loaded.privateKey, "key", "existing key must be preserved when omitted")
        // Presence flags recomputed from actual values, not trusted from app.
        XCTAssertTrue(loaded.hasPassword, "hasPassword must reflect actual secret presence")
        XCTAssertTrue(loaded.hasPrivateKey, "hasPrivateKey must reflect actual secret presence")
    }

    /// When the app explicitly sends a secret (even empty), it must apply.
    func testServerSetAppliesExplicitSecret() {
        let (store, _) = makeStore()
        store.save(sample(id: "1", password: "old"))

        let update: [String: Any] = [
            "id": "1", "name": "h", "host": "h", "port": 22, "username": "r",
            "hostKey": "", "dnsServers": [], "hasPassword": true,
            "password": "new"
        ]
        _ = responseData(makeRouter(store: store), cmd: "serverSet", args: update)!

        XCTAssertEqual(store.load(id: "1")?.password, "new", "explicit password must replace")
    }

    // MARK: - serverDelete

    func testServerDeleteRemovesById() {
        let (store, _) = makeStore()
        store.save(sample(id: "1"))
        store.save(sample(id: "2"))

        let r = responseData(makeRouter(store: store), cmd: "serverDelete", args: ["id": "1"])!
        XCTAssertEqual(r["ok"] as? Bool, true)
        XCTAssertEqual(store.loadAll().count, 1)
        XCTAssertEqual(store.load(id: "2")?.host, "1.2.3.4")
    }

    func testServerDeleteMissingIdReturnsError() {
        let (store, _) = makeStore()
        let r = responseData(makeRouter(store: store), cmd: "serverDelete", args: ["id": "ghost"])!
        XCTAssertEqual(r["ok"] as? Bool, false)
    }

    // MARK: - serverSelect

    func testServerSelectUpdatesActive() {
        let (store, _) = makeStore()
        store.save(sample(id: "1"))
        store.save(sample(id: "2"))

        let r = responseData(makeRouter(store: store), cmd: "serverSelect", args: ["id": "2"])!
        XCTAssertEqual(r["ok"] as? Bool, true)
        XCTAssertEqual(store.selectedID(), "2")
    }

    func testServerSelectMissingIdReturnsError() {
        let (store, _) = makeStore()
        let r = responseData(makeRouter(store: store), cmd: "serverSelect", args: ["id": "ghost"])!
        XCTAssertEqual(r["ok"] as? Bool, false)
    }

    // MARK: - Malformed / unknown

    func testMalformedRequestReturnsError() {
        let (store, _) = makeStore()
        let router = makeRouter(store: store)
        let r = decode(router.handle(garbageData()))!
        XCTAssertEqual(r["ok"] as? Bool, false)
        XCTAssertNotNil((r["data"] as? [String: String])?["error"])
    }

    func testUnknownCmdReturnsError() {
        let (store, _) = makeStore()
        let r = responseData(makeRouter(store: store), cmd: "hack_the_gibson")!
        XCTAssertEqual(r["ok"] as? Bool, false)
        XCTAssertNotNil((r["data"] as? [String: String])?["error"])
    }

    // MARK: - Helpers

    private func garbageData() -> Data {
        Data([0xFF, 0xFE, 0xFD])
    }
}

private extension ServerProfile {
    /// Encodes the profile to a JSON-serializable dictionary for use as the
    /// `args` payload of a `serverSet` command.
    func toJSONDict() -> [String: Any] {
        let data = try! JSONEncoder().encode(self)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}
