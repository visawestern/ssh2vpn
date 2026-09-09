import Foundation
import VPNCore
import CleverAdsSolutions
import UIKit

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

/// CAS.AI rewarded-video wrapper (mediation account pending — runs in
/// DEMO mode meanwhile).
///
/// - Demo mode: casID "demo" + test ad mode per the official docs
///   (docs.page/cleveradssolutions/docs/iOS/Enabling-test-ads). Test ads
///   are safe to click and never flag the future production account.
/// - Production: replace `casID` with the manager ID the CAS account
///   manager assigns (single-line change, see `AdsConfig`).
///
/// Ad-availability policy (AppModel.adsAvailable): rewarded ads are only
/// offered with no tunnel up — through the tunnel the egress country is
/// the server's, which skews the ad networks' country targeting.
enum AdsConfig {
    /// "demo" until the CAS account manager issues the production ID.
    static let casID = "demo"
}

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
