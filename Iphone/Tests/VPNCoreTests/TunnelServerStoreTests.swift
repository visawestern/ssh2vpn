import XCTest
@testable import VPNCore

/// Tests for the extension-owned server list store. The extension persists
/// the full list (including secrets) in its own UserDefaults container; the
/// app never sees secrets — only presence flags. These tests verify the store
/// round-trips correctly against an isolated defaults instance.
final class TunnelServerStoreTests: XCTestCase {

    private func makeStore() -> (TunnelServerStore, UserDefaults) {
        // Use a volatile suite so tests never pollute real storage and run
        // in full isolation from each other.
        let suite = "test.tunnel-server-store.\(UUID().uuidString)"
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

    // MARK: - Empty state

    func testLoadAllReturnsEmptyWhenNothingStored() {
        let (store, _) = makeStore()
        XCTAssertTrue(store.loadAll().isEmpty, "Fresh store must return empty list")
    }

    func testLoadSelectedReturnsNilWhenNothingStored() {
        let (store, _) = makeStore()
        XCTAssertNil(store.selectedID())
    }

    // MARK: - Save + load round-trip

    func testSaveThenLoadRoundTripsAllFields() {
        let (store, _) = makeStore()
        let profile = sample(host: "203.0.113.10", password: "sekret")
        store.save(profile)

        let loaded = store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, "aaa")
        XCTAssertEqual(loaded[0].host, "203.0.113.10")
        XCTAssertEqual(loaded[0].port, 22)
        XCTAssertEqual(loaded[0].username, "root")
        XCTAssertEqual(loaded[0].hostKey, "AAAAB3")
        XCTAssertEqual(loaded[0].dnsServers, ["8.8.8.8"])
        XCTAssertEqual(loaded[0].password, "sekret")
        XCTAssertEqual(loaded[0].hasPassword, true)
    }

    func testSecretsPersistAndFlagsTrackThem() {
        let (store, _) = makeStore()
        store.save(sample(id: "1", password: "p", privateKey: "k"))

        let loaded: ServerProfile = store.load(id: "1")!
        XCTAssertEqual(loaded.password, "p")
        XCTAssertEqual(loaded.privateKey, "k")
        XCTAssertTrue(loaded.hasPassword)
        XCTAssertTrue(loaded.hasPrivateKey)
    }

    func testProfileWithoutSecretsReportsFlagsFalse() {
        let (store, _) = makeStore()
        store.save(sample(id: "x", password: nil, privateKey: nil))

        let loaded: ServerProfile = store.load(id: "x")!
        XCTAssertNil(loaded.password)
        XCTAssertNil(loaded.privateKey)
        XCTAssertFalse(loaded.hasPassword)
        XCTAssertFalse(loaded.hasPrivateKey)
    }

    // MARK: - Insert vs update by id

    func testSaveWithSameIdUpdatesExisting() {
        let (store, _) = makeStore()
        store.save(sample(id: "aaa", host: "1.1.1.1"))
        store.save(sample(id: "aaa", host: "9.9.9.9"))

        let all = store.loadAll()
        XCTAssertEqual(all.count, 1, "Same id must update, not append")
        XCTAssertEqual(all[0].host, "9.9.9.9")
    }

    func testSaveWithDifferentIdAppends() {
        let (store, _) = makeStore()
        store.save(sample(id: "1", host: "1.1.1.1"))
        store.save(sample(id: "2", host: "2.2.2.2"))

        let all = store.loadAll()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(Set(all.map { $0.host }), ["1.1.1.1", "2.2.2.2"])
    }

    // MARK: - Delete

    func testDeleteRemovesById() {
        let (store, _) = makeStore()
        store.save(sample(id: "1"))
        store.save(sample(id: "2"))
        store.delete(id: "1")

        let all = store.loadAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].id, "2")
    }

    func testDeleteMissingIdIsNoOp() {
        let (store, _) = makeStore()
        store.save(sample(id: "1"))
        store.delete(id: "ghost")
        XCTAssertEqual(store.loadAll().count, 1)
    }

    // MARK: - Select

    func testSelectUpdatesSelectedID() {
        let (store, _) = makeStore()
        store.save(sample(id: "1"))
        store.save(sample(id: "2"))
        store.select(id: "2")

        XCTAssertEqual(store.selectedID(), "2")
    }

    func testSelectPersistsAcrossReload() {
        let (store, defaults) = makeStore()
        store.save(sample(id: "1"))
        store.select(id: "1")

        // Fresh store instance against the same backing defaults.
        let reloaded = TunnelServerStore(defaults: defaults)
        XCTAssertEqual(reloaded.selectedID(), "1")
    }

    // MARK: - Clear

    func testClearRemovesEverything() {
        let (store, _) = makeStore()
        store.save(sample(id: "1"))
        store.save(sample(id: "2"))
        store.select(id: "1")
        store.clear()

        XCTAssertTrue(store.loadAll().isEmpty)
        XCTAssertNil(store.selectedID())
    }

    // MARK: - Dedupe flag

    func testDedupeFlagRunsOncePerContainer() {
        let (_, defaults) = makeStore()
        let first = TunnelServerStore(defaults: defaults)
        XCTAssertTrue(first.needsDedupe())
        first.markDeduped()

        let second = TunnelServerStore(defaults: defaults)
        XCTAssertFalse(second.needsDedupe())
    }

    // MARK: - Isolation

    func testVolatileSuiteIsIsolated() {
        // Two stores with different suites must not see each other's data.
        let (a, _) = makeStore()
        let (b, _) = makeStore()
        a.save(sample(id: "1"))
        XCTAssertTrue(b.loadAll().isEmpty)
    }
}
