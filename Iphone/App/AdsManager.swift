import Foundation
import VPNCore
import GoogleMobileAds
import UserMessagingPlatform
import AppLovinSDK
import UIKit

// MARK: - Provider routing

/// Which ad backend the rewarded button uses. AdMob works instantly with
/// the Google-published TEST app ID until the AdMob dashboard issues the
/// real one; AppLovin MAX is wired but awaits account approval (write to
/// account-approval@applovin.com from the developer email).
enum AdsProvider {
    case admob
    case applovinMax

    static let active: AdsProvider = .admob
}

enum AdsConfig {
    /// Own AdMob app ID + own Rewarded ad unit (both dashboard-issued).
    /// PRODUCTION now: real ads, real revenue — DO NOT click/tap the ads
    /// yourself (self-clicks flag the account); the button is only for
    /// real users.
    static let gadAppID = "ca-app-pub-1498434981323978~5326656863"
    static let gadRewardedUnitID = "ca-app-pub-1498434981323978/9602260449"

    /// AppLovin MAX SDK key — "PENDING" until account approval lands.
    static let maxSDKKey = "PENDING"
}

// MARK: - Shared plumbing

/// Guards a Void continuation against double-resume (SDK callback + safety
/// timeout racing). Actor-isolated by the SDK's serialized callback queue in
/// practice; the lock makes it airtight regardless.
final class ResumeOnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ c: CheckedContinuation<Void, Never>) {
        continuation = c
    }

    func resume() {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
    }
}

/// Same one-shot guard for the RewardedAd load continuation (SDK callback
/// vs the 20s timeout task — double resume = continuation misuse crash).
final class AdLoadBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    /// The loaded ad is parked here (non-Sendable — must not cross actor
    /// boundaries); the MainActor continuation carries only the success
    /// flag, and the ad itself is fetched under the same lock.
    private var loadedAd: RewardedAd?

    init() {}

    /// Attaches the continuation (called at flow start).
    func arm(_ c: CheckedContinuation<Bool, Never>) {
        lock.lock()
        continuation = c
        lock.unlock()
    }

    func resume(_ ad: RewardedAd?) {
        lock.lock()
        let c = continuation
        continuation = nil
        loadedAd = ad
        lock.unlock()
        c?.resume(returning: ad != nil)
    }

    /// MainActor pulls the parked ad after the continuation resumes.
    func takeAd() -> RewardedAd? {
        lock.lock()
        let ad = loadedAd
        loadedAd = nil
        lock.unlock()
        return ad
    }
}

/// Why the rewarded flow ended. The button shows a short in-place notice
/// for the failure cases (5s) instead of silently re-enabling.
enum RewardedOutcome {
    /// Watched to the end — reward credited.
    case earned
    /// No ad came up (no fill, UMP consent gate, load timeout) — nothing
    /// to watch, the user did nothing wrong.
    case noFill
    /// An ad played but was dismissed before the earn callback — no
    /// reward this time.
    case dismissedEarly
}

/// Common entry the app calls: initializes the ACTIVE provider and runs the
/// full rewarded flow (consent → load → present).
enum RewardedAdRouter {
    @MainActor
    static func presentRewarded() async -> RewardedOutcome {
        switch AdsProvider.active {
        case .admob:
            AdMobRewardedProvider.shared.initialize()
            return await AdMobRewardedProvider.shared.presentRewarded()
        case .applovinMax:
            guard AdsConfig.maxSDKKey != "PENDING" else {
                ConsoleLogStore.shared.log(level: .warning, tag: "ADS", message: "MAX asleep: SDK key pending account approval")
                return .noFill
            }
            MaxRewardedProvider.shared.initialize()
            return await MaxRewardedProvider.shared.presentRewarded()
        }
    }
}

// MARK: - AdMob (ACTIVE)

/// Google AdMob rewarded wrapper. Same three-step discipline: UMP consent
/// (15s safety timeout — the form can silently never fire its handler) →
/// GADRewardedAd.load (20s no-fill timeout) → present + earn handler;
/// dismissal completes the flow.
final class AdMobRewardedProvider: NSObject, @unchecked Sendable {
    static let shared = AdMobRewardedProvider()

    private var initialized = false
    private var rewardedAd: RewardedAd?
    private let initLock = NSLock()

    private override init() {
        super.init()
    }

    /// Starts the Google Mobile Ads SDK once per launch (idempotent).
    @MainActor
    func initialize() {
        initLock.lock()
        let alreadyInit = initialized
        initialized = true
        initLock.unlock()
        guard !alreadyInit else { return }

        MobileAds.shared.start { status in
            let ok = status.adapterStatusesByClassName.values.allSatisfy { $0.state == .ready }
            ConsoleLogStore.shared.log(level: ok ? .success : .warning, tag: "ADS", message: "GMA start: \(ok ? "ready" : "some adapters not ready")")
        }
        ConsoleLogStore.shared.log(level: .info, tag: "ADS", message: "AdMob rewarded ready (production ad unit)")
    }

    /// Full rewarded flow: consent → load → present.
    @MainActor
    func presentRewarded() async -> RewardedOutcome {
        // 1. UMP consent (GDPR regions). Safety timeout.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let box = ResumeOnceBox(c)
            let parameters = RequestParameters()
            parameters.isTaggedForUnderAgeOfConsent = false
            ConsentInformation.shared.requestConsentInfoUpdate(with: parameters) { _ in box.resume() }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(15))
                box.resume()
            }
        }
        // Present the form only if consent is actually required; errors and
        // the "not required" case both fall through to the ad load.
        let formVC = await TopVCFinder.find()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let box = ResumeOnceBox(c)
            ConsentForm.loadAndPresentIfRequired(from: formVC) { _ in box.resume() }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(15))
                box.resume()
            }
        }
        ConsoleLogStore.shared.log(level: .info, tag: "ADS", message: "UMP consent flow finished (status \(ConsentInformation.shared.consentStatus.rawValue))")

        guard ConsentInformation.shared.canRequestAds else {
            ConsoleLogStore.shared.log(level: .warning, tag: "ADS", message: "UMP: canRequestAds false after consent flow")
            return .noFill
        }

        // 2. Load (20s no-fill timeout). AdLoadBox parks the ad behind
        // its lock; the continuation only carries the ok flag.
        let loadBox = AdLoadBox()
        let loaded = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            loadBox.arm(c)
            RewardedAd.load(with: AdsConfig.gadRewardedUnitID, request: Request()) { ad, error in
                if let error {
                    ConsoleLogStore.shared.log(level: .warning, tag: "ADS", message: "rewarded load failed: \(error.localizedDescription)")
                } else {
                    ConsoleLogStore.shared.log(level: .info, tag: "ADS", message: "rewarded content loaded")
                }
                loadBox.resume(ad)
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(20))
                ConsoleLogStore.shared.log(level: .warning, tag: "ADS", message: "load flow finished: timeout (20s)")
                loadBox.resume(nil)
            }
        }
        guard loaded, let ad = loadBox.takeAd() else { return .noFill }
        self.rewardedAd = ad

        // 3. Present over the top view controller; earn handler fires the
        //    reward, dismissal ends the wait (covers early dismiss too).
        let presentingVC = await topViewController()
        let dismissBox = PresentDismissBox()
        let earnFlag = EarnedFlag()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            dismissBox.arm(c)
            ad.fullScreenContentDelegate = self
            ad.present(from: presentingVC) {
                earnFlag.set(true)
                ConsoleLogStore.shared.log(level: .info, tag: "ADS", message: "reward earned callback")
            }
            // Safety: presentation itself should never hang the button.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(120))
                dismissBox.resume()
            }
        }
        self.rewardedAd = nil
        // earnFlag true = watched to the end; false = dismissed early
        // (the ad DID play, so not a no-fill).
        return earnFlag.read ? .earned : .dismissedEarly
    }

    /// Top-most view controller for fullscreen ad presentation.
    @MainActor
    private func topViewController() async -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows).filter { $0.isKeyWindow }
        guard let window = windows.first else { return nil }
        var top = window.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

extension AdMobRewardedProvider: FullScreenContentDelegate {
    func adWillPresentFullScreenContent(_ ad: FullScreenPresentingAd) {
        ConsoleLogStore.shared.log(level: .info, tag: "ADS", message: "rewarded presented")
    }

    func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        ConsoleLogStore.shared.log(level: .info, tag: "ADS", message: "rewarded dismissed (completing flow)")
        // THE fix: dismissal is the normal end of the presentation wait —
        // without resuming here the button spun until the 120s safety
        // timeout even on a fully earned view.
        AdMobRewardedProvider.activeDismissBox?.resume()
    }

    func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        ConsoleLogStore.shared.log(level: .error, tag: "ADS", message: "rewarded present failed: \(error.localizedDescription)")
        AdMobRewardedProvider.activeDismissBox?.resume()
    }
}

/// Atomic earned flag: the earn handler runs on the SDK thread, the read
/// happens on MainActor after the dismissal continuation resumes.
final class EarnedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set(_ v: Bool) {
        lock.lock()
        value = v
        lock.unlock()
    }

    var read: Bool {
        lock.lock()
        let v = value
        lock.unlock()
        return v
    }
}

/// One-shot resume for the presentation wait: armed on MainActor at
/// present() time, resumed by the delegate's dismiss/fail callbacks (SDK
/// thread) or the 120s safety timeout — whichever fires first.
final class PresentDismissBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    nonisolated(unsafe) static var active: PresentDismissBox?

    init() {}

    func arm(_ c: CheckedContinuation<Void, Never>) {
        lock.lock()
        continuation = c
        lock.unlock()
        Self.active = self
    }

    func resume() {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
        if Self.active === self { Self.active = nil }
    }
}

extension AdMobRewardedProvider {
    /// Delegate callbacks land on the SDK's thread; route them through the
    /// armed PresentDismissBox.
    nonisolated(unsafe) static var activeDismissBox: PresentDismissBox? {
        get { PresentDismissBox.active }
        set { PresentDismissBox.active = newValue }
    }
}

// MARK: - AppLovin MAX (ASLEEP — awaiting account approval)

/// Wires the AppLovin MAX SDK behind AdsProvider.applovinMax. Inactive
/// until AdsConfig.maxSDKKey holds the real key from the MAX dashboard.
final class MaxRewardedProvider: NSObject, @unchecked Sendable {
    static let shared = MaxRewardedProvider()

    private var rewarded: MARewardedAd?

    private override init() {
        super.init()
    }

    func initialize() {
        guard rewarded == nil else { return }
        guard AdsConfig.maxSDKKey != "PENDING" else { return }
        let config = ALSdkInitializationConfiguration(sdkKey: AdsConfig.maxSDKKey) { builder in
            builder.mediationProvider = ALMediationProviderMAX
        }
        ALSdk.shared().initialize(with: config) { _ in
            ConsoleLogStore.shared.log(level: .success, tag: "ADS", message: "MAX SDK initialized")
        }
        let r = MARewardedAd.shared(withAdUnitIdentifier: "MAX_REWARDED_UNIT_ID")
        r.delegate = self
        rewarded = r
        ConsoleLogStore.shared.log(level: .info, tag: "ADS", message: "MAX rewarded ready")
    }

    @MainActor
    func presentRewarded() async -> RewardedOutcome {
        guard let rewarded else { return .noFill }
        // MAX shows consent internally per network; load → show with the
        // same safety-timeout discipline.
        let loaded = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            MaxLoadBox.shared.arm(c, delegate: self)
            rewarded.load()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(20))
                MaxLoadBox.shared.timeout()
            }
        }
        guard loaded else { return .noFill }
        var earned = false
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let box = ResumeOnceBox(c)
            MaxRewardBox.shared.arm { earnedFlag in
                earned = earnedFlag
                box.resume()
            }
            rewarded.show(forPlacement: nil)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(120))
                box.resume()
            }
        }
        // Ad shown: earned = watched to the end, false = early dismiss.
        return earned ? .earned : .dismissedEarly
    }
}

/// Bridges the nonisolated MAX delegate callbacks into the awaiting
/// continuations (delegate methods land on an arbitrary queue).
final class MaxLoadBox: @unchecked Sendable {
    static let shared = MaxLoadBox()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    func arm(_ c: CheckedContinuation<Bool, Never>, delegate: MaxRewardedProvider) {
        lock.lock()
        continuation = c
        lock.unlock()
    }

    func fire(_ ok: Bool) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: ok)
    }

    func timeout() { fire(false) }
}

final class MaxRewardBox: @unchecked Sendable {
    static let shared = MaxRewardBox()
    private let lock = NSLock()
    private var handler: (@MainActor (Bool) -> Void)?
    /// didRewardUser lands BEFORE didHide; remember it, didHide completes
    /// the continuation (pending-reward pattern).
    private var earned = false

    func arm(_ h: @escaping @MainActor (Bool) -> Void) {
        lock.lock()
        handler = h
        earned = false
        lock.unlock()
    }

    func fire(_ earnedFlag: Bool) {
        lock.lock()
        let h = handler
        handler = nil
        lock.unlock()
        guard let h else { return }
        Task { @MainActor in
            h(earnedFlag)
        }
    }

    func setEarned(_ value: Bool) {
        lock.lock()
        earned = value
        lock.unlock()
    }

    var lastEarned: Bool {
        lock.lock()
        let v = earned
        lock.unlock()
        return v
    }
}

enum TopVCFinder {
    @MainActor
    static func find() async -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows).filter { $0.isKeyWindow }
        guard let window = windows.first else { return nil }
        var top = window.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

extension MaxRewardedProvider: MAAdDelegate, MARewardedAdDelegate {
    nonisolated func didLoad(_ ad: MAAd) {
        ConsoleLogStore.shared.log(level: .info, tag: "ADS", message: "MAX rewarded loaded")
        MaxLoadBox.shared.fire(true)
    }

    nonisolated func didFailToLoadAd(forAdUnitIdentifier id: String, withError error: MAError) {
        ConsoleLogStore.shared.log(level: .warning, tag: "ADS", message: "MAX load failed: \(error.message)")
        MaxLoadBox.shared.fire(false)
    }

    nonisolated func didDisplay(_ ad: MAAd) {}
    nonisolated func didClick(_ ad: MAAd) {}

    nonisolated func didHide(_ ad: MAAd) {
        // Reward already fired via didRewardUser before hide.
        MaxRewardBox.shared.fire(MaxRewardBox.shared.lastEarned)
    }

    nonisolated func didFail(toDisplay ad: MAAd, withError error: MAError) {
        MaxRewardBox.shared.fire(false)
    }

    nonisolated func didRewardUser(for ad: MAAd, with reward: MAReward) {
        ConsoleLogStore.shared.log(level: .success, tag: "ADS", message: "MAX reward earned")
        MaxRewardBox.shared.setEarned(true)
    }
}
