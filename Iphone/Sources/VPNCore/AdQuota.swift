import Foundation

/// Free-tier usage budget with rewarded-ad refills (the ad itself is a stub
/// on the client side for now — only the accounting lives here).
///
/// Rules:
///   - every install gets 3 free hours of VPN time;
///   - one ad view adds another 3 hours;
///   - ads can be watched at most once per hour;
///   - at most 3 views can be banked (9 hours of banked credit).
///
/// Pure value type — persistence is AdQuotaStore's job.
public struct AdQuota: Equatable, Sendable {
    public static let freeAllowance: TimeInterval = 3 * 3600
    public static let rewardPerView: TimeInterval = 3 * 3600
    public static let viewCooldown: TimeInterval = 3600
    public static let maxBankedViews = 3

    /// Free seconds already consumed (against the initial 3h grant).
    public private(set) var usedFreeSeconds: TimeInterval
    /// Banked ad-credit seconds (consumption drains the free grant first).
    public private(set) var bankedSeconds: TimeInterval
    /// When the last ad was watched (for the 1/hour cooldown).
    public private(set) var lastViewAt: Date?

    public init(usedFreeSeconds: TimeInterval = 0, bankedSeconds: TimeInterval = 0, lastViewAt: Date? = nil) {
        self.usedFreeSeconds = usedFreeSeconds
        self.bankedSeconds = bankedSeconds
        self.lastViewAt = lastViewAt
    }

    /// Total remaining connection time right now (free remainder + banked).
    public var remainingSeconds: TimeInterval {
        max(0, AdQuota.freeAllowance - usedFreeSeconds) + bankedSeconds
    }

    /// A view is allowed when the 1h cooldown passed AND the bank isn't full.
    public func canWatchAd(now: Date) -> Bool {
        if bankedSeconds >= AdQuota.maxBankedSecondsAsTime { return false }
        guard let last = lastViewAt else { return true }
        return now.timeIntervalSince(last) >= AdQuota.viewCooldown
    }

    /// Seconds until the next view is allowed (0 when canWatchAd is true).
    public func adCooldownRemaining(now: Date) -> TimeInterval {
        guard !canWatchAd(now: now) else { return 0 }
        if bankedSeconds >= AdQuota.maxBankedSecondsAsTime { return 0 } // capped, not cooling
        guard let last = lastViewAt else { return 0 }
        return max(0, AdQuota.viewCooldown - now.timeIntervalSince(last))
    }

    /// Consumes connected time: drains the free grant first, then the bank.
    public mutating func consume(_ seconds: TimeInterval) {
        guard seconds > 0 else { return }
        let freeLeft = max(0, AdQuota.freeAllowance - usedFreeSeconds)
        let fromFree = min(freeLeft, seconds)
        usedFreeSeconds += fromFree
        let rest = seconds - fromFree
        if rest > 0 { bankedSeconds = max(0, bankedSeconds - rest) }
    }

    /// Records an ad view; false when not allowed (cooldown / bank full).
    @discardableResult
    public mutating func watchAd(now: Date) -> Bool {
        guard canWatchAd(now: now) else { return false }
        bankedSeconds = min(AdQuota.maxBankedSecondsAsTime, bankedSeconds + AdQuota.rewardPerView)
        lastViewAt = now
        return true
    }

    private static var maxBankedSecondsAsTime: TimeInterval {
        TimeInterval(maxBankedViews) * rewardPerView
    }
}

/// UserDefaults-backed persistence for AdQuota (plain container defaults —
/// the app and extension both count time independently of each other, only
/// the app enforces).
public struct AdQuotaStore {
    private let defaults: UserDefaults
    private let usedKey = "adQuota.usedFreeSeconds.v1"
    private let bankedKey = "adQuota.bankedSeconds.v1"
    private let lastViewKey = "adQuota.lastViewAt.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AdQuota {
        AdQuota(
            usedFreeSeconds: defaults.double(forKey: usedKey),
            bankedSeconds: defaults.double(forKey: bankedKey),
            lastViewAt: defaults.object(forKey: lastViewKey) as? Date
        )
    }

    public func save(_ quota: AdQuota) {
        defaults.set(quota.usedFreeSeconds, forKey: usedKey)
        defaults.set(quota.bankedSeconds, forKey: bankedKey)
        defaults.set(quota.lastViewAt, forKey: lastViewKey)
    }
}
