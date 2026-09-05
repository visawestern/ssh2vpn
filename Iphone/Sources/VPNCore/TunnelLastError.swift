import Foundation
import Security

/// Last tunnel failure persisted where BOTH the packet-tunnel extension and
/// the app can reach it after the extension process dies.
///
/// Why this exists: extension logs live in process memory. When startTunnel
/// throws (SSH refused, fail2ban RST, bad config) the process is torn down
/// within ~100ms and the message channel dies with it — the app then sees
/// `phase=idle, extError=none` and retries blindly, which hammers the server
/// into a fail2ban lockout. There is no app-group entitlement on this
/// project, so the shared keychain group (present in BOTH entitlements) is
/// the only post-mortem channel.
///
/// Write on every extension failure path; clear on successful establish;
/// the app reads it when the message channel is dead.
public enum TunnelLastError {
    private static let service = "com.ssh2vpn.tunnel-last-error"
    private static let account = "lastError"
    /// Must match `keychain-access-groups` in SSH2VPN.entitlements and
    /// SSH2VPNPacketTunnel.entitlements (TeamID prefix + suite id).
    private static let accessGroup = "568467VWR6.com.sshtunnel.shared"

    private static func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrAccessGroup as String: accessGroup]
    }

    /// Best-effort persist (never throws — logging must not crash a tunnel).
    public static func write(_ message: String) {
        guard let data = String(message.prefix(512)).data(using: .utf8) else { return }
        SecItemDelete(baseQuery() as CFDictionary)
        var add = baseQuery()
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        _ = SecItemAdd(add as CFDictionary, nil)
    }

    /// Returns the persisted failure, if any.
    public static func read() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }
}
