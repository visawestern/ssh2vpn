import Foundation
import Security

public protocol CredentialVault: Sendable {
    func read(_ account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
    func remove(_ account: String) throws
}

public enum CredentialVaultError: Error, LocalizedError {
    case unavailable(Int32)
    public var errorDescription: String? { "Secure storage is unavailable. Unlock your device and try again." }
}

/// Shared between the app and its packet-tunnel extension. Never synchronized to iCloud.
public struct KeychainCredentialVault: CredentialVault {
    public init() {}
    private func query(_ account: String) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.sshtunnel.secure.v2", kSecAttrAccount as String: account]
        #if os(iOS)
        let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String ?? ""
        query[kSecAttrAccessGroup as String] = prefix + "com.sshtunnel.shared"
        #endif
        return query
    }
    public func read(_ account: String) throws -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CredentialVaultError.unavailable(status) }
        return data
    }
    public func write(_ data: Data, account: String) throws {
        let query = query(account)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw CredentialVaultError.unavailable(updated) }
        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw CredentialVaultError.unavailable(status) }
    }
    public func remove(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialVaultError.unavailable(status) }
    }
}

public struct ServerSecrets: Codable, Sendable {
    public var password: String?
    public var privateKey: String?
    public init(password: String?, privateKey: String?) { self.password = password; self.privateKey = privateKey }
    public static func account(host: String, port: Int, username: String) -> String {
        // Structured encoding avoids collisions between host, port and username.
        "endpoint:" + (try! JSONEncoder().encode([host.lowercased(), String(port), username])).base64EncodedString()
    }
}

/// Trust on first use: remember the first key, reject changes on subsequent connections.
/// For first-connection authentication, users can instead supply a verified public host key.
public enum HostKeyTrust {
    private static let lock = NSLock()
    public static func verify(key: String, host: String, port: Int, vault: any CredentialVault = KeychainCredentialVault()) throws {
        lock.lock()
        defer { lock.unlock() }
        let account = "host-key:" + ServerSecrets.account(host: host, port: port, username: "")
        let data = Data(key.utf8)
        if let stored = try vault.read(account) {
            guard stored == data else { throw SSHTransportError.hostKeyMismatch }
        } else {
            try vault.write(data, account: account)
        }
    }
}
