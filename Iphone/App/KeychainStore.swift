import Foundation
import Security

enum KeychainStore {
    private static let service = "com.sshtunnel.credentials"
    private static var accessGroup: String {
        let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String ?? ""
        return prefix + "com.sshtunnel.shared"
    }

    static func save(password: String, account: String) throws {
        let data = Data(password.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecAttrAccessGroup as String: accessGroup]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    static func read(account: String) throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecAttrAccessGroup as String: accessGroup,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw KeychainError.status(status) }
        return value
    }

    static func contains(account: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecAttrAccessGroup as String: accessGroup,
                                    kSecReturnData as String: false,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    enum KeychainError: Error { case status(OSStatus) }
}
