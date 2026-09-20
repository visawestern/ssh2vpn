import Foundation
import VPNCore
import GoogleMobileAds
import UserMessagingPlatform
import UIKit
import AppTrackingTransparency

// MARK: - Ad config

enum AdsConfig {
    /// AdMob app ID (ours, dashboard-issued — kept so the store listing
    /// verifies against our account) + Rewarded ad unit.
    /// TEMPORARY: Google's OFFICIAL iOS rewarded TEST unit. AdMob serves no
    /// production fill until it verifies our App Store URL, so production
    /// units return no-fill everywhere (review + early users): the +3h
    /// button would look dead. Test units make the full watch→earn→credit
    /// path provable in review; the creative itself is labeled "Test Ad" by
    /// Google. Declared in Review Notes. DO NOT tap (self-clicks flag the
    /// account even on test units); the button is only for real users.
    /// SWAP BACK to "ca-app-pub-1498434981323978/9602260449" + resubmit the
    /// moment AdMob links the live listing — that update is one line.
    static let gadAppID = "ca-app-pub-1498434981323978~5326656863"
    static let gadRewardedUnitID = "ca-app-pub-3940256099942544/1712485313"
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
        guard let c = continuation else { lock.unlock(); return }
        continuation = nil
        loadedAd = ad
        lock.unlock()
        c.resume(returning: ad != nil)
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

/// Common entry the app calls: initializes AdMob and runs the full
/// rewarded flow (consent → load → present). AdMob is the ONLY ad SDK in
/// the binary (no mediation, no MAX) — one backend, one audit trail.
enum RewardedAdRouter {
    @MainActor
    static func presentRewarded() async -> RewardedOutcome {
        return await AdMobRewardedProvider.shared.presentRewarded()
    }
}

@MainActor
enum AdvertisingPrivacy {
    static var optionsRequired: Bool {
        ConsentInformation.shared.privacyOptionsRequirementStatus == .required
    }
    static func showOptions() async throws {
        try await ConsentForm.presentPrivacyOptionsForm(from: await TopVCFinder.find())
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
        do {
            try await ConsentForm.loadAndPresentIfRequired(from: formVC)
        } catch {
            return .noFill
        }
        ConsoleLogStore.shared.log(level: .info, tag: "ADS", message: "UMP consent flow finished (status \(ConsentInformation.shared.consentStatus.rawValue))")

        guard ConsentInformation.shared.canRequestAds else {
            ConsoleLogStore.shared.log(level: .warning, tag: "ADS", message: "UMP: canRequestAds false after consent flow")
            return .noFill
        }

        // The SDK is started only for a user-requested ad, after applicable consent.
        if ATTrackingManager.trackingAuthorizationStatus == .notDetermined {
            _ = await ATTrackingManager.requestTrackingAuthorization()
        }
        initialize()

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
