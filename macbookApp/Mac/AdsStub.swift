import Foundation

/// MAC-замена Iphone/App/AdsManager.swift (AdMob/UMP — iOS-only, на macOS
/// их SDK не существует).
///
/// Сохраняет ТОЧНО те же имена типов и API, чтобы общие вью (RootView)
/// компилировались без изменений:
/// - `RewardedOutcome` — те же три кейса;
/// - `RewardedAdRouter.presentRewarded()` — STUB: реклама временно
///   отключена, награда выдаётся сразу без просмотра (.earned);
/// - `AdvertisingPrivacy` — privacy options никогда не требуются.
enum RewardedOutcome {
    case earned
    case noFill
    case dismissedEarly
}

enum RewardedAdRouter {
    @MainActor
    static func presentRewarded() async -> RewardedOutcome {
        // STUB: настоящего показа нет — сразу награда (+3ч через creditAdView).
        .earned
    }
}

@MainActor
enum AdvertisingPrivacy {
    static var optionsRequired: Bool { false }
    static func showOptions() async throws {}
}
