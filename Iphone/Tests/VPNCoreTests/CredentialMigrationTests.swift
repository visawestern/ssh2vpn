import XCTest
@testable import VPNCore

final class CredentialMigrationTests: XCTestCase {
    func testLegacySecretsMigrateAndNewPasswordsReplaceOldOnes() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let vault = TestCredentialVault()
        let store = TunnelServerStore(defaults: defaults, vault: vault)
        var profile = ServerProfile(id: "a", name: "test", host: "example.com", port: 22, username: "user", hostKey: "", dnsServers: [], hasPassword: true, hasPrivateKey: false, password: "OLD_TEST_SECRET")
        defaults.set(try JSONEncoder().encode([profile]), forKey: "tunnel.servers.v1")
        XCTAssertEqual(store.loadAll().first?.password, "OLD_TEST_SECRET")
        XCTAssertFalse(String(decoding: defaults.data(forKey: "tunnel.servers.v1")!, as: UTF8.self).contains("OLD_TEST_SECRET"))
        profile.password = "NEW_TEST_SECRET"
        XCTAssertTrue(store.save(profile))
        XCTAssertEqual(store.loadAll().first?.password, "NEW_TEST_SECRET")
        XCTAssertFalse(String(decoding: defaults.data(forKey: "tunnel.servers.v1")!, as: UTF8.self).contains("NEW_TEST_SECRET"))
    }
    func testFailedMigrationKeepsLegacyDataAndFailedSaveDoesNotReplaceIt() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let vault = TestCredentialVault(); vault.failWrites = true
        let store = TunnelServerStore(defaults: defaults, vault: vault)
        let profile = ServerProfile(id: "a", name: "test", host: "example.com", port: 22, username: "user", hostKey: "", dnsServers: [], hasPassword: true, hasPrivateKey: false, password: "TEST_SECRET")
        let legacy = try JSONEncoder().encode([profile])
        defaults.set(legacy, forKey: "tunnel.servers.v1")
        XCTAssertEqual(store.loadAll().first?.password, "TEST_SECRET")
        XCTAssertFalse(store.save(profile))
        XCTAssertEqual(defaults.data(forKey: "tunnel.servers.v1"), legacy)
    }
    func testFirstHostKeyIsRememberedAndChangedKeyRejected() throws {
        let vault = TestCredentialVault()
        try HostKeyTrust.verify(key: "key-A", host: "example.com", port: 22, vault: vault)
        try HostKeyTrust.verify(key: "key-A", host: "EXAMPLE.COM", port: 22, vault: vault)
        XCTAssertThrowsError(try HostKeyTrust.verify(key: "key-B", host: "example.com", port: 22, vault: vault))
        try HostKeyTrust.verify(key: "key-B", host: "example.com", port: 2222, vault: vault)
    }
}
