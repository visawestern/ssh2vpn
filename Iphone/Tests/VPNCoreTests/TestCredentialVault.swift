import Foundation
@testable import VPNCore

final class TestCredentialVault: CredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    var failWrites = false
    func read(_ account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }; return values[account]
    }
    func write(_ data: Data, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failWrites { throw CredentialVaultError.unavailable(-1) }
        values[account] = data
    }
    func remove(_ account: String) throws {
        lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: account)
    }
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [ObjectIdentifier: TestCredentialVault] = [:]
    static func forDefaults(_ defaults: UserDefaults) -> TestCredentialVault {
        registryLock.lock(); defer { registryLock.unlock() }
        let id = ObjectIdentifier(defaults)
        if let existing = registry[id] { return existing }
        let vault = TestCredentialVault(); registry[id] = vault; return vault
    }
}
