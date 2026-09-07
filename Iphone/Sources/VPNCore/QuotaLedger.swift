import Foundation
import Security

/// The usage budget for VPN time, shared between the app and the packet-tunnel
/// extension through the KEYCHAIN access group (there is deliberately no
/// app-group / shared UserDefaults).
///
/// WHY the extension is the source of truth:
///   A naive implementation meters a session inside the app UI, so starting the
///   tunnel from iOS Settings (which bypasses the app entirely) never touches
///   the budget — the "3 hours" never tick and an expired user keeps connecting.
///   This ledger is written/read by BOTH sides, but only the extension ENFORCES
///   it: on every startTunnel it reads it from the keychain and refuses if the
///   wall-clock budget is gone. The app cannot be bypassed because the check
///   happens in the running extension regardless of how the tunnel was started.
///
/// Accounting model — WALL CLOCK (decided with the owner):
///   - fresh install: 1 real hour granted at first launch (expiry = now + 1h);
///   - one rewarded ad: +3 real hours, but only one press per hour (cooldown);
///   - the bank can never exceed 12 real hours total at any moment (cap);
///   - $5 one-time purchase: `unlimited = true`, ads removed, gate removed;
///   - the budget ticks down in real time whether or not the tunnel is up.
public struct QuotaLedger: Equatable, Sendable, Codable {
    public static let initialGrantSeconds: TimeInterval = 3600
    public static let adRewardSeconds: TimeInterval = 3 * 3600
    public static let adCooldownSeconds: TimeInterval = 3600
    public static let maxBudgetSeconds: TimeInterval = 12 * 3600

    public static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// One-time purchase holder; when true neither the gate nor the refund
    /// applies — tunneling is simply allowed.
    public private(set) var unlimited: Bool
    /// Wall-clock moment the current budget lapses (nil when unlimited, or
    /// when no budget has ever been granted).
    public private(set) var expiresAt: Date?
    /// Wall-clock moment of the last rewarded-ad press (drives the hourly
    /// cooldown). Nil until the first press.
    public private(set) var lastAdViewAt: Date?

    public var unlimitedValue: Bool { unlimited }
    public var expires: Date? { expiresAt }
    public var lastAdView: Date? { lastAdViewAt }

    public init(unlimited: Bool = false, expiresAt: Date? = nil, lastAdViewAt: Date? = nil) {
        self.unlimited = unlimited
        self.expiresAt = expiresAt
        self.lastAdViewAt = lastAdViewAt
    }

    /// Real seconds of budget remaining right now (0 once lapsed).
    public func remaining(now: Date) -> TimeInterval {
        guard !unlimited, let expiresAt else { return 0 }
        return max(0, expiresAt.timeIntervalSince(now))
    }

    public var isUnlimited: Bool { unlimited }

    /// Whether a tunnel may start right now under the kernel enforcement.
    public func allowsConnection(now: Date) -> Bool {
        unlimited || remaining(now: now) > 0
    }

    /// Grants the initial free allowance if none exists and no purchase yet.
    public func withInitialGrant(now: Date) -> QuotaLedger {
        guard !unlimited, expiresAt == nil else { return self }
        var l = self
        l.expiresAt = now.addingTimeInterval(Self.initialGrantSeconds)
        return l
    }

    /// One rewarded view: +adRewardSeconds of wall-clock, gated by the hourly
    /// cooldown and the 12h bank ceiling. Returns nil when the view can't be
    /// credited (unlimited already, cooldown running, or bank at the cap).
    public func creditingAdView(now: Date) -> QuotaLedger? {
        guard !unlimited else { return nil }
        if let last = lastAdViewAt, now.timeIntervalSince(last) < Self.adCooldownSeconds {
            return nil
        }
        let effective = remaining(now: now)
        // Cap: the bank can never exceed 12 real hours at any moment; at the
        // ceiling there is nothing left to buy.
        if effective >= Self.maxBudgetSeconds { return nil }
        var l = self
        let base = max(now, expiresAt ?? now)
        // Extend from where the budget currently points, but never beyond
        // now + 12h — the cap's clamp, not a refusal, near the top.
        l.expiresAt = min(base.addingTimeInterval(Self.adRewardSeconds),
                          now.addingTimeInterval(Self.maxBudgetSeconds))
        l.lastAdViewAt = now
        return l
    }

    /// Applies a one-time purchase: removes the gate and hides ads.
    public func withUnlimited() -> QuotaLedger {
        var l = self
        l.unlimited = true
        l.expiresAt = nil
        return l
    }

    public func removingUnlimited() -> QuotaLedger {
        var l = self
        l.unlimited = false
        return l
    }
}

// MARK: - Keychain-backed storage (shared with the packet-tunnel extension)

/// Persists a QuotaLedger inside the shared keychain access group so the app
/// and the extension see the SAME budget. The extension is the enforcer; the
/// app writes on purchase / ad-view / first-launch.
public struct QuotaLedgerStore {
    private static let service = "com.sshtunnel.quota"
    private static let account = "ledger.v1"
    private static let accessGroup = "com.sshtunnel.shared"

    private static var resolvedAccessGroup: String {
        let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String ?? ""
        return prefix + accessGroup
    }

    public init() {}

    public func load() -> QuotaLedger {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrAccessGroup as String: Self.resolvedAccessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return QuotaLedger() }
        return (try? JSONDecoder().decode(QuotaLedger.self, from: data)) ?? QuotaLedger()
    }

    @discardableResult
    public func save(_ ledger: QuotaLedger) -> Bool {
        guard let data = try? JSONEncoder().encode(ledger) else { return false }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrAccessGroup as String: Self.resolvedAccessGroup,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        return status == errSecSuccess
    }
}
