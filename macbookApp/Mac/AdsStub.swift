import Foundation

/// MAC-замена Iphone/App/AdsManager.swift (AdMob/UMP — iOS-only, на macOS
/// их SDK не существует).
///
/// Сохраняет ТОЧНО те же имена типов и API, чтобы общие вью (RootView)
/// компилировались без изменений:
/// - `RewardedOutcome` — те же три кейса;
/// - `RewardedAdRouter.presentRewarded()` — всегда `.noFill` (UI этот путь
///   не вызывает: `AppModel.canWatchAd` на macOS всегда false);
/// - `AdvertisingPrivacy` — privacy options никогда не требуются.
enum RewardedOutcome {
    case earned
    case noFill
    case dismissedEarly
}

enum RewardedAdRouter {
    @MainActor
    static func presentRewarded() async -> RewardedOutcome {
        .noFill
    }
}

@MainActor
enum AdvertisingPrivacy {
    static var optionsRequired: Bool { false }
    static func showOptions() async throws {}
}
