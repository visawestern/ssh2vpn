import Foundation
import VPNCore
import GoogleMobileAds
import UserMessagingPlatform
import AppLovinSDK
import CleverAdsSolutions
import UIKit

// MARK: - Provider routing

/// Which ad backend the rewarded button uses. CAS is asleep (account
/// manager never responded after 24h+); AdMob works instantly with the
/// Google-published TEST app ID until the AdMob dashboard issues the real
/// one; AppLovin MAX is wired but awaits account approval (write to
/// account-approval@applovin.com from the developer email).
enum AdsProvider {
    case cas
    case admob
    case applovinMax

    static let active: AdsProvider = .admob
}

enum AdsConfig {
    /// CAS "demo" (account manager pending — asleep).
    static let casID = "demo"

    /// Google's official TEST app ID / rewarded ad unit
    /// (developers.google.com/admob/ios/quick-start). Safe to click, never
    /// flags the future production account. Replace both with the AdMob
    /// dashboard values once the app is registered there.
    static let gadAppID = "ca-app-pub-3940256099942544~1458002511"
    static let gadRewardedUnitID = "ca-app-pub-3940256099942544/1712485313"

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

/// Common entry the app calls: initializes the ACTIVE provider and runs the
/// full rewarded flow (consent → load → present). Returns true when the
/// user completed the view and earned the reward.
enum RewardedAdRouter {
    @MainActor
    static func presentRewarded() async -> Bool {
        switch AdsProvider.active {
        case .admob:
            await AdMobRewardedProvider.shared.initialize()
            return await AdMobRewardedProvider.shared.presentRewarded()
        case .applovinMax:
            guard AdsConfig.maxSDKKey != "PENDING" else {
                ConsoleLogStore.shared.log(level: .warning, tag: "ADS", message: "MAX asleep: SDK key pending account approval")
                return false
            }
            MaxRewardedProvider.shared.initialize()
            return await MaxRewardedProvider.shared.presentRewarded()
        case .cas:
            RewardedAdCoordinator.shared.initialize()
            return await RewardedAdCoordinator.shared.presentRewarded()
        }
    }
}

// MARK: - AdMob (ACTIVE)

/// Google AdMob rewarded wrapper. Same three-step discipline the CAS flow
/// had: UMP consent (15s safety timeout — the form can silently never fire
/// its handler) → GADRewardedAd.load (20s no-fill timeout) → present +
/// earn handler; dismissal completes the flow.
final class AdMobRewardedProvider: NSObject, @unchecked Sendable {
    nonisolated(unsafe) static let shared = AdMobRewardedProvider()

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
        ConsoleLogStore.shared.log(level: .info, tag: "ADS", message: "AdMob rewarded ready (TEST app ID, test ad unit)")
    }

    /// Full rewarded flow: consent → load → present. True = earned.
    @MainActor
    func presentRewarded() async -> Bool {
        // 1. UMP consent (GDPR regions). Safety timeout like the CAS flow.
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
            return false
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
        guard loaded, let ad = loadBox.takeAd() else { return false }
        self.rewardedAd = ad

        // 3. Present over the top view controller; earn handler fires the
        //    reward, dismissal ends the wait (covers early dismiss too).
        let presentingVC = await topViewController()
        var earned = false
        let dismissed = await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let box = ResumeOnceBox(c)
            ad.fullScreenContentDelegate = self
            ad.present(from: presentingVC) {
                earned = true
                ConsoleLogStore.shared.log(level: .info, tag: "ADS", message: "reward earned callback")
            }
            // Safety: presentation itself should never hang the button.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(120))
                box.resume()
            }
        }
        _ = dismissed
        self.rewardedAd = nil
        return earned
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
        ConsoleLogStore.shared.log(level: .info, tag: "ADS", message: "rewarded dismissed")
    }

    func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        ConsoleLogStore.shared.log(level: .error, tag: "ADS", message: "rewarded present failed: \(error.localizedDescription)")
    }
}

// MARK: - AppLovin MAX (ASLEEP — awaiting account approval)

/// Wires the AppLovin MAX SDK behind AdsProvider.applovinMax. Inactive
/// until AdsConfig.maxSDKKey holds the real key from the MAX dashboard.
final class MaxRewardedProvider: NSObject, @unchecked Sendable {
    nonisolated(unsafe) static let shared = MaxRewardedProvider()

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
    func presentRewarded() async -> Bool {
        guard let rewarded else { return false }
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
        guard loaded else { return false }
        let presentingVC = await TopVCFinder.find()
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
        return earned
    }
}

/// Bridges the nonisolated MAX delegate callbacks into the awaiting
/// continuations (delegate methods land on an arbitrary queue).
final class MaxLoadBox: @unchecked Sendable {
    nonisolated(unsafe) static let shared = MaxLoadBox()
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
    nonisolated(unsafe) static let shared = MaxRewardBox()
    private let lock = NSLock()
    private var handler: (@MainActor (Bool) -> Void)?
    /// didRewardUser lands BEFORE didHide; remember it, didHide completes
    /// the continuation (mirrors the CAS pendingRewardEarned pattern).
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

// MARK: - CAS.AI (ASLEEP — account manager pending)

/// Original CAS.AI rewarded-video wrapper, kept intact for a single-flag
/// reactivation if the manager ever responds. Not routed to while
/// AdsProvider.active != .cas.
///
/// Ad-availability policy (AppModel.adsAvailable): rewarded ads are only
/// offered with no tunnel up — through the tunnel the egress country is
/// the server's, which skews the ad networks' country targeting.
///
/// Owns the CASRewarded instance; bridges delegate callbacks into
/// async/await so AppModel.watchAd() stays linear.
///
/// Presentation sequence (per CAS docs): consent form if required →
/// loadAd() → wait for screenAdDidLoadContent → present → earn callback
/// fires on a completed view → screenAdDidDismissContent completes the
/// continuation.
final class RewardedAdCoordinator: NSObject, ObservableObject {
    nonisolated(unsafe) static let shared = RewardedAdCoordinator()

    private var rewarded: CASRewarded?
    /// Resumes presentRewarded(); nil between requests.
    private var earnHandler: (@MainActor (Bool) -> Void)?
    /// Resumes waitForLoad(); nil between requests.
    private var loadHandler: (@MainActor (Bool) -> Void)?
    private var pendingRewardEarned = false
    /// Guards handler extraction when the SDK delegate queue races the
    /// MainActor timeout task (double resume = continuation misuse crash).
    private let finishLock = NSLock()

    private override init() {
        super.init()
    }

    /// Initializes CAS once per launch (idempotent).
    func initialize() {
        guard rewarded == nil else { return }
        // Audience: our app is an SSH utility for adults — explicitly mark
        // NOT-children so the "Audience: Undefined" warning disappears and
        // ad filters don't downgrade to kid-safe (much lower eCPM).
        CAS.settings.taggedAudience = .notChildren
        let builder = CAS.buildManager()
        builder.withCompletionHandler { config in
            if let error = config.error {
                ConsoleLogStore.shared.log(level: .warning, tag: "ADS", message: "CAS init error: \(error)")
            } else {
                ConsoleLogStore.shared.log(level: .success, tag: "ADS", message: "CAS ready (country \(config.countryCode ?? "?"), consent required: \(config.isConsentRequired))")
            }
        }
        builder.withTestAdMode(true)
        builder.create(withCasId: AdsConfig.casID)
        let r = CASRewarded(casID: AdsConfig.casID)
        r.delegate = self
        // Loads are explicit (loadAd on each request) — no background
        // preload while the user might be connecting the tunnel.
        r.isAutoloadEnabled = false
        rewarded = r
        ConsoleLogStore.shared.log(level: .info, tag: "ADS", message: "CAS rewarded ready (demo ID, test ad mode)")
    }

    /// Full rewarded flow: consent → load → present. Returns true when the
    /// user completed the view (SDK earn callback), false on any failure,
    /// no-fill timeout, or early dismissal.
    @MainActor
    func presentRewarded() async -> Bool {
        guard let rewarded else { return false }

        // 1. Consent form first (GDPR regions). If it shows, the user
        //    answers it; the completion fires regardless. Safety timeout:
        //    the SDK can silently never fire the handler (webview failed,
        //    "auto consent not fired" path) — that previously left the
        //    button spinning forever.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let box = ResumeOnceBox(c)
            CASConsentFlow()
                .withCompletionHandler { _ in box.resume() }
                .presentIfRequired()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(15))
                box.resume()
            }
        }
        ConsoleLogStore.shared.log(level: .info, tag: "ADS", message: "consent flow finished")

        // 2. Load, then wait for the delegate's loaded/failed callback.
        let loaded = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            loadHandler = { ok in c.resume(returning: ok) }
            rewarded.loadAd()
            // No-fill safety: don't hang the button forever.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(20))
                self?.finishLoadHandler(false, reason: "load timeout (20s)")
            }
        }
        guard loaded else { return false }

        // 3. Present and wait for earn + dismissal. Present over the app's
        //    top view controller — passing nil leaves some networks unable
        //    to attach their fullscreen view, which stalled the flow.
        let presentingVC = await topViewController()
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            earnHandler = { earned in c.resume(returning: earned) }
            rewarded.present(from: presentingVC) { [weak self] _ in
                // Earned fires before dismissal; remember it, the dismiss
                // delegate call completes the continuation.
                self?.markRewardEarned()
            }
        }
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

    /// Nonisolated entry from the SDK callback queue (callbacks are
    /// serialized by the SDK, so the flag is race-free in practice).
    nonisolated private func markRewardEarned() {
        pendingRewardEarned = true
    }
}

extension RewardedAdCoordinator: CASScreenContentDelegate {
    func screenAdDidLoadContent(_ ad: any CASScreenContent) {
        ConsoleLogStore.shared.log(level: .info, tag: "ADS", message: "rewarded content loaded")
        finishLoadHandler(true, reason: nil)
    }

    func screenAd(_ ad: any CASScreenContent, didFailToLoadWithError error: AdError) {
        ConsoleLogStore.shared.log(level: .warning, tag: "ADS", message: "rewarded load failed: \(error.description)")
        finishLoadHandler(false, reason: error.description)
    }

    func screenAdWillPresentContent(_ ad: any CASScreenContent) {
        ConsoleLogStore.shared.log(level: .info, tag: "ADS", message: "rewarded presented")
    }

    func screenAd(_ ad: any CASScreenContent, didFailToPresentWithError error: AdError) {
        ConsoleLogStore.shared.log(level: .error, tag: "ADS", message: "rewarded present failed: \(error.description)")
        finishEarnHandler(false)
    }

    func screenAdDidClickContent(_ ad: any CASScreenContent) {
        ConsoleLogStore.shared.log(level: .info, tag: "ADS", message: "rewarded clicked")
    }

    func screenAdDidDismissContent(_ ad: any CASScreenContent) {
        ConsoleLogStore.shared.log(level: .info, tag: "ADS", message: "rewarded dismissed")
        let earned = pendingRewardEarned
        pendingRewardEarned = false
        finishEarnHandler(earned)
    }

    /// Resumes the load continuation exactly once (timeout task on MainActor
    /// can race the SDK delegate on its own queue — the lock keeps the
    /// extraction atomic).
    private func finishLoadHandler(_ ok: Bool, reason: String?) {
        finishLock.lock()
        let handler = loadHandler
        loadHandler = nil
        finishLock.unlock()
        guard let handler else { return }
        if let reason {
            ConsoleLogStore.shared.log(level: .warning, tag: "ADS", message: "load flow finished: \(reason)")
        }
        Task { @MainActor in
            handler(ok)
        }
    }

    /// Resumes the earn continuation exactly once.
    private func finishEarnHandler(_ earned: Bool) {
        finishLock.lock()
        let handler = earnHandler
        earnHandler = nil
        finishLock.unlock()
        guard let handler else { return }
        Task { @MainActor in
            handler(earned)
        }
    }
}
