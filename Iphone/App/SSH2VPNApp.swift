import SwiftUI
import StoreKit
import Network
@preconcurrency import NetworkExtension
import VPNCore
import os
import AppTrackingTransparency

@main
struct SSH2VPNApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
#if DEBUG
                // DEBUG-ONLY agent channel (loopback + token, read-only).
                // Compiles out of Release entirely — see DebugCtlServer.swift.
                .task { await DebugCtlServer.shared.start(model: model) }
#endif
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedLanguage: AppLanguage? = LanguageStore.current
    /// True while the first-launch language screen waits for the device +
    /// IP-country language hints (max 10s — then the plain list is shown,
    /// the user picks by hand).
    @Published var languageHintsResolving = false
    @Published var connection = ConnectionPresentation.disconnected {
        didSet {
            updateIdleTimer()
            updateConsoleGrace(previous: oldValue)
        }
    }
    /// Wall-clock moment the last session ended (disconnect / failure). Used
    /// for the post-disconnect stats tick window.
    @Published var lastDisconnectAt: Date?
    @Published var serverName = "My VPS"

    // MARK: - Live tunnel stats (polled from the extension every 2s)
    /// Pooled SSH connections to the server right now.
    @Published var sshConnectionCount = 0
    /// Live direct-tcpip channels across the pool (real active data streams).
    @Published var activeChannelCount = 0
    /// Cumulative tunnel bytes this session (phone -> server / server -> phone).
    @Published var tunnelUpBytes = 0
    @Published var tunnelDownBytes = 0
    private var statsPollTask: Task<Void, Never>?

    // MARK: - Usage budget (1h free wall-clock from FIRST USE, then rewarded-ad refills, or
    // unlimited one-time purchase). The grant starts on the first Connect tap
    // or the first rewarded ad — never on install, so a fresh-looking app
    // never shows an already-burned 0:00. The ENFORCEMENT lives in the
    // extension (QuotaLedgerStore, shared keychain); the app only displays it and
    // writes credit (ad view / purchase). Starting the tunnel from iOS
    // Settings still obeys the kernel gate because the extension checks the
    // same ledger on start.
    @Published var quota: QuotaLedger = QuotaLedgerStore().load()
    /// True while the ad is "playing" (disables the button).
    @Published var adPlaying = false
    /// Short-lived in-button notice after a failed rewarded attempt
    /// (no fill / early dismissal). Shown by the button for ~5s.
    @Published var adNoticeKey: CopyKey?
    @Published var adNoticeUntil = Date.distantPast
    /// Real user country (detected while the tunnel is DOWN so the ad SDK
    /// gets honest geo targeting). Ads are blocked whenever the tunnel is
    /// up or connecting — the exit country would skew the campaign.
    @Published var userCountryCode: String?

    /// Rewarded ads are offered whenever NO tunnel is up: `.disconnected`
    /// OR `.failed` (a failed start — e.g. the free-time gate blocking
    /// connect at 00:00 — leaves no tunnel, so the user's egress country is
    /// still honest). Blocked only while `.connecting`/`.connected`, where
    /// the egress country would be the server's and skew ad targeting.
    var adsAvailable: Bool {
        connection == .disconnected || connection == .failed("freeTimeExhausted") || connection == .failed("quotaExhausted")
    }

    /// StoreKit purchase + entitlement restore for Unlimited.
    let store = StoreManager()

    // MARK: - Paywall (stateless: both prices on every opening)
    // Every presentation shows the SAME content: the discounted offer AND
    // the regular price, side by side. No stages, no one-time flags, no
    // UserDefaults-gated content — nothing can appear once and then hide
    // between openings (Guideline 5.6). Dismissing always just closes —
    // the close button never escalates, never locks, never timers.
    // Not shown to users who already own Unlimited.
    @Published var isPaywallPresented = false

    func showPaywall() {
        guard !isUnlimited else { return }
        isPaywallPresented = true
    }

    func paywallPaid() {
        reloadQuota()
        isPaywallPresented = false
    }

    /// Dismisses the paywall (user closed it). Always just closes — no
    /// escalation, no timers, no locks, no state changes.
    func dismissPaywall() {
        isPaywallPresented = false
    }

    // Local copy of the server list (plain UserDefaults in the app container).
    // This is the UI source of truth: add/select/delete apply instantly even
    // when the extension isn't reachable (fresh install, tunnel down). The
    // extension keeps its own copy — synced best-effort over the message API
    // plus persisted on every startTunnel — and never returns secrets back.
    private let localStore = TunnelServerStore()
    @Published var servers: [ServerProfile] = []
    @Published var selectedServer: ServerProfile?

    /// One-time server-dedupe flag: hygiene runs exactly once ever, never on
    /// every load.
    private static let serverDedupeKey = "ssh2vpn.serverDedupeDone.v1"
    private static var serverDedupeDone: Bool {
        get { UserDefaults.standard.bool(forKey: serverDedupeKey) }
        set { UserDefaults.standard.set(newValue, forKey: serverDedupeKey) }
    }

    /// Bundle version for logs/dumps — read live so it can never go stale
    /// after a version bump (a hardcoded string once misled a diagnosis).
    static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    /// Backward-compatible single-profile view derived from the selected server.
    /// Existing UI code reads `profile`; this keeps it working while the data
    /// of record lives in the extension.
    var profile: VPNProfile {
        guard let s = selectedServer else {
            return VPNProfile(host: "", port: 22, username: "", password: "", privateKey: "", hostKey: "")
        }
        return VPNProfile(host: s.host, port: s.port, username: s.username,
                          password: s.password ?? "", privateKey: s.privateKey ?? "",
                          hostKey: s.hostKey, dnsServers: s.dnsServers)
    }

    @Published var settings: AppSettingsState = SettingsStore.load() {
        didSet { SettingsStore.save(settings) }
    }
    private var automation = VPNConnectionAutomation(maxRetries: 3)
    /// When the current attempt's startVPNTunnel was invoked. Lets the
    /// disconnect handler tell an early death (tunnel flapped seconds after
    /// start, first-start flake) from a real mid-session drop.
    private var attemptStartedAt: Date?
    @Published var serverCountry: String = ""
    @Published var serverCountryCode: String = ""
    @Published var serverFlag: String = "🌐"
    @Published var serverCity: String = ""
    @Published var serverPingMs: Int? = nil
    @Published var serverLatitude: Double = 50.1109
    @Published var serverLongitude: Double = 8.6821
    @Published var isResolvingMetadata: Bool = false
    /// True only when the selected server has a real map position. Location
    /// is fully on-device (bundled RIR prefix table + country centroids):
    /// no IP is ever sent to a geo service, so there is nothing extra to
    /// declare to App Review. Only unresolvable hosts show host/ping with
    /// no map dot; the map never implies a location we did not determine.
    @Published var hasServerGeo = false
    /// GeoIP runs once per host (on server-list updates), never on every
    /// connect/reconnect — ping stays live, geo does not spam.
    private var lastGeoHost: String? = nil

    // Per-server metadata cache (populated on server-list load).
    @Published var serverGeoCache: [String: ServerGeoInfo] = [:]
    @Published var serverPingCache: [String: Int] = [:]
    /// Minutely ping refresher (ping only — GeoIP stays cached from load).
    private var serverPingTimer: Timer?
    /// Decorative-ping budget: max 4 port-22 SYNs per 30s (server allows ~6;
    /// the rest is headroom for real SSH connects). Stops the UI from
    /// tripping the VPS rate limiter during burst testing.
    private let pingBudget = PingBudget()
    /// Stall watchdog state: the minutely ping guarantees utun traffic, so a
    /// frozen read counter across cycles means iOS stopped feeding the tunnel.
    private var lastStallRead: Int?
    private var stallFrozenCycles = 0
    /// Set while a stall restart is in flight: the old tunnel's goodbye
    /// DISCONNECTED is expected and must not trigger early-death diagnosis.
    private var stallRestartArmed = false
    /// Set while the user WANTED the connection (kill-switch auto-reconnect):
    /// an unexpected disconnect then re-dials automatically with backoff
    /// instead of dropping the phone onto the raw network.
    private var userIntentConnected = false
    /// Set when the model adopted a LIVE tunnel discovered on foreground
    /// return / resync (out-of-band start, e.g. from Settings or surviving a
    /// relaunch). Such a tunnel's disconnect events are REAL (something of
    /// ours IS running) but didInvokeStart is false — this flag lets the
    /// status observer's stale-churn filter accept them instead of dropping
    /// a genuine death and leaving an adopted tunnel stuck "connected".
    private var adoptedLiveTunnel = false
    private var killSwitchAttempts = 0
    /// Connect-storm circuit breaker: trips after 10 consecutive failed
    /// attempts (see tripCircuitBreaker). Fresh user intent and any success
    /// re-arm it; a kill-switch redial must NOT reset it.
    private var breaker = ConnectionBreaker()

    private let vpn = VPNController()
    private var statusObserver: NSObjectProtocol?
    // Last raw VPN status seen (for burst-dedupe of the log only).
    private var lastRawStatus: NEVPNStatus?
    private var lastRawAt: Date?
    // Live phase polling while connecting.
    private var phasePollTask: Task<Void, Never>?
    private var lastPolledPhase: String?
    private var reportedLiveErrors = Set<String>()

    /// Dedicated server-list loader. Reads the local store synchronously so
    /// the UI updates instantly. Safe to call repeatedly ("poll each time").
    func loadServerList() {
        // One-time hygiene: drop duplicate records left by earlier builds.
        if !Self.serverDedupeDone {
            Self.serverDedupeDone = true
            let dupes = ServerDedupe.duplicateIDs(servers: localStore.loadAll(), selectedID: localStore.selectedID())
            for id in dupes { localStore.delete(id: id) }
            if !dupes.isEmpty {
                ConsoleLogStore.shared.log(level: .warning, tag: "VPN", message: "Removed \(dupes.count) duplicate server(s) (one-time hygiene)")
            }
        }
        let all = localStore.loadAll()
        servers = all
        let sel = localStore.selectedID()
        selectedServer = all.first { $0.id == sel } ?? all.first
        // First launch only: resolve the device + IP-country language hints
        // for the overlay's pinned entries (10s cap — never block the user).
        if needsLanguageSelection {
            resolveLanguageHints()
        }
        refreshServerMetadata()
        refreshAllServerMetadata()
    }

    /// Adds or updates a server locally (instant UI), then best-effort syncs
    /// it to the extension (applies when the tunnel/manager is reachable).
    func saveServer(_ profile: ServerProfile) throws {
        var p = profile
        p.hasPassword = p.password?.isEmpty == false
        p.hasPrivateKey = p.privateKey?.isEmpty == false
        guard localStore.save(p) else { throw CredentialVaultError.unavailable(-1) }
        localStore.select(id: p.id)
        loadServerList()
        Task { @MainActor in
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                vpn.ensureManagerLoaded { continuation.resume() }
            }
            await VPNExtensionAPI.saveServer(p, to: vpn.diagnosticManager())
            await VPNExtensionAPI.selectServer(id: p.id, from: vpn.diagnosticManager())
        }
    }

    /// Pulls the extension's authoritative copy of one server (via serverGet)
    /// so the EDIT form pre-fills with live data, not the app's stale local
    /// snapshot. Secrets never come back — the router strips them — and the
    /// form keeps its own "blank = keep stored secret" merge semantics.
    @MainActor
    func fetchServerForEdit(id: String) async -> ServerProfile? {
        // Make sure the provider manager exists (message channel carrier).
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            vpn.ensureManagerLoaded { continuation.resume() }
        }
        let d = await VPNExtensionAPI.call(from: vpn.diagnosticManager(), cmd: .serverGet, args: ["id": id])
        guard let json = d["server"], let raw = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ServerProfile.self, from: raw)
    }

    /// Removes a server locally (instant UI), then best-effort syncs the
    /// deletion to the extension.
    func deleteServer(id: String) {
        localStore.delete(id: id)
        if selectedServer?.id == id {
            selectedServer = nil
        }
        loadServerList()
        Task { @MainActor in
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                vpn.ensureManagerLoaded { continuation.resume() }
            }
            await VPNExtensionAPI.deleteServer(id: id, from: vpn.diagnosticManager())
        }
    }

    /// Selects the active server (the one used for the next connection).
    /// Locked while a connection exists or is being established: switching
    /// servers mid-flight would silently split the session (old tunnel keeps
    /// the old server, UI shows the new one). Disconnect first.
    func selectServer(id: String) {
        // Trust-but-verify: if the model still thinks a tunnel is up while
        // NetworkExtension says otherwise (missed disconnect event, dead
        // extension), the block below would refuse a switch the user can
        // plainly see should work. Re-sync from the real NE status first.
        resyncConnectionStateWithSystem()
        guard connection != .connected, connection != .connecting else {
            ConsoleLogStore.shared.log(level: .warning, tag: "SERVER", message: "Server switch BLOCKED: a connection is active or starting — disconnect first")
            return
        }
        localStore.select(id: id)
        selectedServer = servers.first { $0.id == id }
        refreshServerMetadata()
        ConsoleLogStore.shared.log(level: .success, tag: "SERVER",
            message: "switched to \(selectedServer?.host ?? id) — applies on next connect")
        Task { @MainActor in
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                vpn.ensureManagerLoaded { continuation.resume() }
            }
            await VPNExtensionAPI.selectServer(id: id, from: vpn.diagnosticManager())
        }
    }

    /// Foreground-return hook: re-derives the model's connection state from
    /// the system. Called on every didBecomeActive so a tunnel that died or
    /// came up while the app was suspended (missed NEVPNStatusDidChange
    /// events) is reflected the moment the user sees the app again. The core
    /// never resets on its own just because the UI went away — this sync is
    /// the "UI catches up to the kernel" direction.
    private func syncConnectionStateOnForeground() {
        resyncConnectionStateWithSystem()
    }

    /// Reconciles the model's connection state with what NetworkExtension
    /// actually reports. Heals the drift where the UI keeps showing
    /// connected/connecting after the tunnel died without a status event —
    /// that drift froze server switching even though "nothing was running".
    /// Also adopts a tunnel that came up out of band (on-demand, system
    /// restart, or simply events missed while the app was suspended), and
    /// is safe to call from any state: every branch re-derives the correct
    /// timers, automation flags and kill-switch bookkeeping.
    func resyncConnectionStateWithSystem() {
        // The manager may not be loaded yet on a cold launch — load it, then
        // re-sync: the foreground-return path must not silently no-op just
        // because the first resolve hadn't finished yet.
        guard vpn.currentSystemStatus() != nil else {
            Task { @MainActor [weak self] in
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    self?.vpn.ensureManagerLoaded { continuation.resume() }
                }
                self?.reconcileConnectionState()
            }
            return
        }
        reconcileConnectionState()
    }

    /// Core of the state reconciliation, called once the manager is loaded
    /// (ground truth is available). Maps every NEVPNStatus to the
    /// presentation it deserves and heals every direction of drift: a live
    /// tunnel the model missed (suspended app, cold relaunch, started from
    /// Settings) is adopted; a dead tunnel the model still shows is fully
    /// unwound — including the kill-switch redial the missed .disconnected
    /// event would have scheduled.
    private func reconcileConnectionState() {
        guard let status = vpn.currentSystemStatus() else { return }
        switch status {
        case .disconnected, .invalid:
            guard connection == .connected || connection == .connecting else { return }
            ConsoleLogStore.shared.log(level: .warning, tag: "SERVER",
                message: "state drift healed: model said \(connection) but the tunnel is actually down")
            adoptDisconnectedState()
        case .connected:
            guard connection != .connected else { return }
            ConsoleLogStore.shared.log(level: .warning, tag: "SERVER",
                message: "state resync: model said \(connection) but the tunnel is actually UP")
            adoptLiveTunnelState(.connected)
        case .connecting, .reasserting, .disconnecting:
            // Only adopt when the model thinks nothing is happening — a
            // mid-connect attempt or a reasserting live tunnel self-heals via
            // real status events; only the "nothing at all" state is wrong.
            guard connection == .disconnected || isFailedState(connection) else { return }
            ConsoleLogStore.shared.log(level: .warning, tag: "SERVER",
                message: "state resync: model said \(connection) but the tunnel is actually starting (\(status.rawValue))")
            adoptLiveTunnelState(.connecting)
        @unknown default:
            return
        }
    }

    private func isFailedState(_ state: ConnectionPresentation) -> Bool {
        if case .failed = state { return true }
        return false
    }

    /// Applies everything a real CONNECTED/CONNECTING event would have set.
    /// Mirrors handleVPNStatusChange(.connected): automation, stats polling,
    /// timer keep-alive and the console/log inventory — so an adopted tunnel
    /// behaves identically to one whose events were received live.
    private func adoptLiveTunnelState(_ presentation: ConnectionPresentation) {
        connection = presentation
        userIntentConnected = true
        adoptedLiveTunnel = true
        if presentation == .connected {
            _ = automation.markConnected()
            killSwitchAttempts = 0
            breaker.reset()
            attemptStartedAt = nil
            stallRestartArmed = false
            lastStallRead = nil
            stallFrozenCycles = 0
            startStatsPolling()
            ConsoleLogStore.shared.log(level: .success, tag: "TUNNEL", message: ">> TUNNEL ADOPTED (still/now running) << model state restored from NetworkExtension")
            logExtensionInventory()
            pushFullDNSRulesAfterConnect()
        } else {
            attemptStartedAt = Date()
            startPhasePolling()
        }
        startDisplayTimerIfNeeded()
    }

    /// Applies everything a real DISCONNECTED event would have set. Used by
    /// the drift heal so a stale "connected" fully unwinds (timers, polls,
    /// kill-switch armed state) instead of leaving orphaned background work.
    /// The kill-switch branch mirrors handleVPNStatusChange(.disconnected):
    /// the missed event never armed its redial, so heal it here.
    private func adoptDisconnectedState() {
        let wasConnected = connection == .connected
        let wanted = userIntentConnected
        let adopted = adoptedLiveTunnel
        connection = .disconnected
        adoptedLiveTunnel = false
        stopPhasePolling()
        stopStatsPolling()
        attemptStartedAt = nil
        if (wanted || adopted), wasConnected, settings.killSwitch {
            // Keep the intent: the redial task's guard requires it, same as
            // the live handler which leaves it true while re-dialing.
            userIntentConnected = true
            ConsoleLogStore.shared.log(level: .warning, tag: "KILLSWITCH",
                message: "tunnel death was missed while the app was away — arming redial now")
            scheduleKillSwitchReconnect()
        } else {
            userIntentConnected = false
        }
    }

    func deleteProfile() {
        // Legacy single-profile delete clears the selected server.
        if let id = selectedServer?.id {
            deleteServer(id: id)
        }
        selectedServer = nil
        serverName = "My VPS"
        serverFlag = "🌐"
        serverCountry = ""
        serverCountryCode = ""
        serverCity = ""
        serverLatitude = 50.1109
        serverLongitude = 8.6821
        serverPingMs = nil
        hasServerGeo = false
    }

    init() {
        statusObserver = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] note in
            // Observer runs on queue: .main, so this closure is always on the
            // main actor in practice — assert it and delegate all state work.
            guard let connection = note.object as? NEVPNConnection else { return }
            MainActor.assumeIsolated {
                self?.handleVPNStatusChange(connection)
            }
        }
        ConsoleLogStore.shared.log(level: .system, tag: "BOOT", message: "SSH2VPN v\(Self.appVersion) diagnostics log initialized")
        // Re-apply the idle-lock whenever the app enters the foreground so the
        // screen stays on for the whole time the user is inside the app.
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateIdleTimer()
                // The tunnel lives in its own extension process and keeps
                // running (or dying) while the app is suspended or even
                // terminated — but NEVPNStatusDidChange events posted during
                // suspension never reach the model. Re-sync on every return
                // to the foreground so the UI always shows the real state.
                self?.syncConnectionStateOnForeground()
            }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateIdleTimer()
            }
        }
        refreshServerMetadata()
        // Load the local server list on launch (instant, no extension needed).
        loadServerList()
        startServerPingTimer()
        // Warm the NE manager in the background so status re-syncs (server
        // switching, connect gating) always have the real system state.
        vpn.ensureManagerLoaded { }
        // Sync usage budget + honors a StoreKit purchase (e.g. the user
        // reinstalled the app; the entitlement survives in App Store).
        reloadQuota()
        Task { @MainActor [weak self] in
            // Re-read the real App Store purchase on every launch. If it was
            // revoked/deleted in StoreKit (e.g. a refunded test purchase), the
            // unlimited flag is also cleared from the shared ledger so the app
            // truly returns to the free tier instead of staying stuck paid.
            // Reload quota into memory either way so the main screen's ad /
            // counter UI reflects the cleared (or re-applied) state instantly.
            let owned = await self?.store.refreshEntitlementClearingIfRevoked() ?? false
            self?.reloadQuota()
            _ = owned
        }
    }

    /// Main-actor body of the NEVPNStatusDidChange handler. The observer
    /// closure (queue: .main) hops here via MainActor.assumeIsolated, so all
    /// model state mutations stay on the main actor without Sendable dance.
    private func handleVPNStatusChange(_ connection: NEVPNConnection) {
        // Ignore chatter from stale/foreign VPN profiles: only our
        // manager's connection may drive UI state and diagnostics.
        if !vpn.owns(connection) { return }
        // Pre-invoke stale filter: nothing of ours is running yet, so a
        // disconnect here is definitionally stale (prefs churn re-posting
        // DISCONNECTED) — accepting it would clobber a fresh .connecting
        // and orphan the whole attempt. Real failures always arrive AFTER
        // startVPNTunnel was invoked, when the flag is set.
        // Exception: an ADOPTED tunnel (a live tunnel the model learned
        // about via resync, e.g. started from Settings or surviving a
        // relaunch) — its death is real, accept it.
        if connection.status == .disconnected || connection.status == .disconnecting {
            if !vpn.didInvokeStart && !adoptedLiveTunnel { return }
        }
        // Collapse identical bursts (system double-posts) in the log.
        // State below still updates, so a repeated status is harmless.
        let now = Date()
        if !TunnelLogDedupe.shouldLog(current: connection.status, last: lastRawStatus, lastAt: lastRawAt, now: now) {
            return
        }
        lastRawStatus = connection.status
        lastRawAt = now
        switch connection.status {
        case .connecting:
            self.connection = .connecting
            ConsoleLogStore.shared.log(level: .ssh, tag: "TUNNEL", message: "PacketTunnel state -> CONNECTING...")
        case .reasserting:
            self.connection = .connecting
            ConsoleLogStore.shared.log(level: .warning, tag: "TUNNEL", message: "PacketTunnel state -> REASSERTING")
        case .connected:
            _ = automation.markConnected()
            self.connection = .connected
            userIntentConnected = true
            killSwitchAttempts = 0
            breaker.reset()
            startStatsPolling()
            attemptStartedAt = nil
            stallRestartArmed = false
            lastStallRead = nil
            stallFrozenCycles = 0
            stopPhasePolling()
            ConsoleLogStore.shared.log(level: .success, tag: "TUNNEL", message: ">> ENCRYPTED TUNNEL ESTABLISHED << IP route 0.0.0.0/0 active")
            logExtensionInventory()
            pushFullDNSRulesAfterConnect()
            schedulePostConnectCheck()
        case .disconnecting:
            ConsoleLogStore.shared.log(level: .info, tag: "TUNNEL", message: "PacketTunnel state -> DISCONNECTING...")
        case .disconnected:
            if stallRestartArmed {
                // Expected goodbye from the old tunnel during a stall
                // restart; the fresh attempt is already in flight. Consume
                // the flag and leave .connecting alone.
                stallRestartArmed = false
                ConsoleLogStore.shared.log(level: .info, tag: "TUNNEL", message: "PacketTunnel state -> DISCONNECTED (stale drop from stall restart, new attempt in flight)")
            } else if self.connection == .connecting, isEarlyDeath() {
                ConsoleLogStore.shared.log(level: .info, tag: "TUNNEL", message: "PacketTunnel state -> DISCONNECTED (early, attempt in flight — diagnosing)")
                diagnoseEarlyDeathAndMaybeRetry()
            } else {
                self.connection = .disconnected
                adoptedLiveTunnel = false
                stopPhasePolling()
                stopStatsPolling()
                attemptStartedAt = nil
                ConsoleLogStore.shared.log(level: .info, tag: "TUNNEL", message: "PacketTunnel state -> DISCONNECTED")
                fetchTunnelDiagnostics()
                scheduleZombieTunnelCheck()
                // Kill switch (Advanced settings): the tunnel died on its
                // own while the user wanted it ON — redial automatically
                // with exponential backoff instead of silently dropping
                // the phone onto the raw network.
                if userIntentConnected, settings.killSwitch {
                    scheduleKillSwitchReconnect()
                } else {
                    userIntentConnected = false
                }
            }
        case .invalid:
            self.connection = .disconnected
            adoptedLiveTunnel = false
            stopPhasePolling()
            attemptStartedAt = nil
            ConsoleLogStore.shared.log(level: .error, tag: "TUNNEL", message: "PacketTunnel state -> INVALID CONFIGURATION — removing broken profile, tap connect to recreate")
            repairInvalidProfile()
        @unknown default:
            self.connection = .failed("Unknown VPN state")
            stopPhasePolling()
            ConsoleLogStore.shared.log(level: .error, tag: "TUNNEL", message: "PacketTunnel state -> UNKNOWN")
        }
    }

    /// Confirms the extension-owned copy after a successful connect (the tunnel
    /// is running here, so the message channel is alive).
    private func logExtensionInventory() {
        Task { @MainActor in
            let d = await VPNExtensionAPI.call(from: vpn.diagnosticManager(), cmd: .serverList)
            let (servers, selectedID) = ServerListCoder.decodeServerList(data: d)
            ConsoleLogStore.shared.log(level: .info, tag: "TUNNEL", message: "Extension store holds \(servers.count) server(s), selected=\(selectedID ?? "none")")
            // Pull the extension's own detail lines (SSH stages) now that the
            // channel is warm, then report live counters. Honors the
            // Enable-Logging setting: off = no extension log ingestion.
            if settings.enableLogging {
                await VPNExtensionAPI.fetchLogs(from: vpn.diagnosticManager())
            }
            logTunnelCounters(tag: "up")
        }
    }

    /// Logs utun packets read/written + live SSH sessions. The decisive
    /// routing evidence: read==0 while browsing means iOS never feeds packets
    /// into our interface.
    private func logTunnelCounters(tag: String) {
        Task { @MainActor in
            let status = await VPNExtensionAPI.call(from: vpn.diagnosticManager(), cmd: .status, timeout: 2)
            let r = status["packetsRead"] ?? "?"
            let w = status["packetsWritten"] ?? "?"
            let replied = status["replied"] ?? "?"
            let s = status["sessions"] ?? "?"
            let phase = status["phase"] ?? "?"
            let proto = status["proto"] ?? "?"
            ConsoleLogStore.shared.log(level: .info, tag: "TUNNEL", message: "Tunnel counters [\(tag)]: utun read=\(r) written=\(w) replied=\(replied) sessions=\(s) phase=\(phase) proto[\(proto)]")
        }
    }

    /// Kicks off the post-connect traffic self-test (SSH banner against the
    /// user's own server + server-reported egress IP). The phone contacts no
    /// third party here — only its own server, directly and over SSH.
    /// Runs detached so blocking DNS never touches the main thread; results
    /// land in the console log.
    private func runPostConnectSelfTest() {
        guard let selected = selectedServer else {
            ConsoleLogStore.shared.log(level: .warning, tag: "SELFTEST", message: "skipped: no selected server")
            return
        }
        let host = selected.host
        let port = selected.port
        Task { @MainActor in
            let before = await self.utunReadCount()
            // Blocking DNS resolve stays off the main thread; awaits below
            // never block (NWConnection suspends, not spins).
            let resolved = await Task.detached { (try? SSHEndpointResolver.resolve(host))?.ipv4 ?? [] }.value
            // Egress report comes from the extension: the SERVER reads its own
            // routing table over SSH exec (local lookup, zero traffic sent
            // anywhere). Empty when the tunnel is down or the server cannot
            // tell (no iproute2) — then the check stays "unverified" instead
            // of failing.
            let rsp = await VPNExtensionAPI.call(from: self.vpn.diagnosticManager(), cmd: .egressCheck, timeout: 25)
            let report = SSHExecCheck.parse(rsp["output"] ?? "")
            let egressOK = await TunnelSelfTester.run(
                expectedHost: host,
                resolvedIPv4: resolved,
                sshPort: port,
                serverReport: report,
                utunReadBefore: before
            )
            // Routing verdict: did ANY self-test packet reach utun?
            if let after = await self.utunReadCount() {
                let delta = after - (before ?? after)
                ConsoleLogStore.shared.log(level: .info, tag: "SELFTEST", message: "utun read after=\(after) (delta=\(delta))")
                if !egressOK && delta <= 0 {
                    ConsoleLogStore.shared.log(level: .error, tag: "SELFTEST", message: "verdict: ROUTING — zero utun packets during self-test, iOS never fed traffic to the tunnel (routes/NWPath), not a relay bug")
                } else if !egressOK && delta > 0 {
                    ConsoleLogStore.shared.log(level: .error, tag: "SELFTEST", message: "verdict: RELAY — traffic reached utun (+\(delta) pkts) but no egress reply; relay/DNS blackhole suspect")
                }
            }
        }
    }

#if DEBUG
    /// DEBUG-ONLY entry for the agent channel (Phase 2 mutations).
    /// Same fire-and-forget path as the automatic post-connect check —
    /// the verdict lands in the console log (`SELFTEST` tag).
    func debugRunSelfTest() {
        runPostConnectSelfTest()
    }

    /// DEBUG-ONLY language switch for localized screenshot runs.
    /// Same `choose` path as the in-app language picker. Returns false
    /// for unknown codes.
    func debugChooseLanguage(code: String) -> Bool {
        guard let lang = AppLanguage(rawValue: code) else { return false }
        choose(lang)
        return true
    }
#endif

    /// Current utun packets-read counter from the extension (nil when the
    /// message channel is unreachable). Used to prove whether self-test
    /// traffic ever reached the tunnel.
    private func utunReadCount() async -> Int? {
        let status = await VPNExtensionAPI.call(from: vpn.diagnosticManager(), cmd: .status, timeout: 2)
        return status["packetsRead"].flatMap(Int.init)
    }

    /// Re-checks counters a while after connect while still connected, so the
    /// dump shows whether traffic actually flows (call sites: .connected).
    /// Runs 12s after connect and ONLY while still connected: fetches logs +
    /// counters first, then the traffic self-test. No checks run on the fresh
    /// CONNECTED event itself — the tunnel (channels, DNS relay, routes) needs
    /// those seconds to settle, otherwise the verdict measures warmup noise.
    private func schedulePostConnectCheck() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(12))
            guard connection == .connected else { return }
            if settings.enableLogging {
                await VPNExtensionAPI.fetchLogs(from: vpn.diagnosticManager(), timeout: 2)
            }
            logTunnelCounters(tag: "+12s")
            self.runPostConnectSelfTest()
        }
    }

    /// Repairs a system-reported INVALID profile: deletes every profile owned
    /// by this app so the next tap recreates it from scratch. A wedged
    /// profile never heals itself — without this the user is stuck forever.
    private func repairInvalidProfile() {
        vpn.removeAllProfiles { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.connection = .failed("VPN profile was invalid and has been removed — tap connect to recreate it.")
                ConsoleLogStore.shared.log(level: .info, tag: "VPN", message: "Broken VPN profile removed; ready to recreate on next connect")
            }
        }
    }

    // MARK: - Zombie-tunnel watchdog (self-healing "no internet" state)
    //
    // Failure mode: the extension dies or is torn down while NetworkExtension
    // still holds the tunnel's default route + DNS binding. The phone then
    // sends everything into a dead utun — the user sees "Wi-Fi connected, no
    // internet" until they toggle Wi-Fi or reinstall the VPN profile.
    // Detection: after ANY disconnect, wait 3s for iOS to clean up its
    // interfaces; if our tunnel's subnet is STILL assigned to an interface
    // while we are disconnected, the cleanup never happened. Repair: remove
    // the VPN profile entirely (the one action iOS guarantees unwinds all
    // routes/DNS of a packet tunnel), then recreate it on the next connect.

    // MARK: - Kill-switch auto-reconnect (unexpected drops only)

    /// Re-dials after the tunnel died on its own while the user wanted it.
    /// Exponential backoff 1s..1h; resets on success or a manual connect.
    private func scheduleKillSwitchReconnect() {
        killSwitchAttempts += 1
        let delay = min(3600.0, pow(2.0, Double(min(killSwitchAttempts, 12))))
        ConsoleLogStore.shared.log(level: .warning, tag: "KILLSWITCH",
            message: "tunnel dropped while kill switch is ON — auto-reconnecting in \(Int(delay))s (attempt \(killSwitchAttempts))")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            // The user may have disconnected (or reconnected manually) during
            // the backoff — the redial is only for a still-wanted tunnel.
            guard self.userIntentConnected, self.settings.killSwitch,
                  self.connection == .disconnected else { return }
            guard self.quota.allowsConnection(now: Date()) else {
                ConsoleLogStore.shared.log(level: .warning, tag: "KILLSWITCH", message: "auto-reconnect skipped: free time exhausted")
                self.userIntentConnected = false
                return
            }
            guard let selected = self.selectedServer else { return }
            ConsoleLogStore.shared.log(level: .info, tag: "KILLSWITCH", message: "auto-reconnecting to \(selected.host)...")
            self.connect(manual: false)
        }
    }

    /// The storm stop: 10 consecutive failed attempts. Disables
    /// connect-on-demand at the NE level (saved to preferences, so iOS stops
    /// relaunching a dead tunnel on every network blip) and parks the
    /// app-side redial via userIntentConnected=false. settings.killSwitch is
    /// DELIBERATELY left ON — the user's kill-switch posture doesn't change,
    /// only the auto-dial storm stops. A manual connect() re-arms everything
    /// (breaker reset + on-demand re-applied per settings).
    private func tripCircuitBreaker() {
        userIntentConnected = false
        vpn.clearOnDemandRules()
        ConsoleLogStore.shared.log(level: .error, tag: "BREAKER",
            message: "CIRCUIT BREAKER: \(breaker.consecutiveFailures) consecutive failures — connect-on-demand DISABLED (iOS will no longer relaunch the tunnel); kill switch stays ON in settings; tap Connect to retry manually")
    }

    private func scheduleZombieTunnelCheck() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.connection == .disconnected else { return }
            // Our tunnel's primary /24 always comes from 10.203.x.x (the
            // historic TunnelDevice range — see TunnelSubnetPicker.candidates).
            // The fallbacks (172.31.x, 192.168.2xx.x) are NOT safe to detect
            // on: home Wi-Fi legitimately lives there. So we only flag a utun
            // holding a 10.203/16 address while we are disconnected — nothing
            // else on iOS uses that range.
            let stuck = LocalInterfaceNets.listIPv4Interfaces().filter { iface in
                let tunnel16 = IPv4Net(addr: (10 << 24) | (203 << 16), prefix: 16)
                return tunnel16.overlaps(IPv4Net(addr: iface.net.addr, prefix: iface.net.prefix))
            }
            guard !stuck.isEmpty else { return }
            let names = stuck.map { "\($0.name) \($0.net.description)" }.joined(separator: ", ")
            ConsoleLogStore.shared.log(level: .error, tag: "HEAL",
                message: "zombie tunnel detected after disconnect ([\(names)]) — iOS kept the dead utun; removing VPN profile to restore internet")
            // Full profile removal is the guaranteed unwind: same mechanism as
            // deleting the VPN in Settings, which is the manual fix for this
            // exact symptom. The next connect rebuilds the profile from scratch.
            self.vpn.removeAllProfiles { [weak self] in
                guard self != nil else { return }
                Task { @MainActor in
                    ConsoleLogStore.shared.log(level: .success, tag: "HEAL",
                        message: "VPN profile removed — routes/DNS unwound; next connect recreates it clean")
                }
            }
        }
    }

    /// Pulls the last tunnel error + status from the extension and logs them.
    /// Called on disconnect/invalid so the app dump reveals WHY the tunnel died
    /// (auth failure, config error, etc.) without needing a shared container.
    private func fetchTunnelDiagnostics() {
        // Keychain first: it survives the extension process death that makes
        // the message channel return [:] below.
        if let persisted = TunnelLastError.read() {
            ConsoleLogStore.shared.log(level: .error, tag: "TUNNEL", message: "Last tunnel error (persisted): \(persisted)")
        }
        Task { @MainActor in
            let lastError = await VPNExtensionAPI.call(from: vpn.diagnosticManager(), cmd: .lastError)
            if let err = lastError["error"], err != "none" {
                ConsoleLogStore.shared.log(level: .error, tag: "TUNNEL", message: "Last tunnel error: \(err)")
            }
            let status = await VPNExtensionAPI.call(from: vpn.diagnosticManager(), cmd: .status)
            if let phase = status["phase"] {
                ConsoleLogStore.shared.log(level: .info, tag: "TUNNEL", message: "Tunnel phase at disconnect: \(phase)")
            }
            if let stop = status["stopReason"], stop != "none" {
                ConsoleLogStore.shared.log(level: .warning, tag: "TUNNEL", message: "Tunnel stop reason: \(stop)")
            }
            // Final pull of the extension's own detail lines (SSH stages).
            if settings.enableLogging {
                await VPNExtensionAPI.fetchLogs(from: vpn.diagnosticManager())
            }
        }
        // Second pass after the extension has settled: stopTunnel runs
        // asynchronously, so the first query can overtake it and see "none".
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            let lastError = await VPNExtensionAPI.call(from: vpn.diagnosticManager(), cmd: .lastError)
            if let err = lastError["error"], err != "none" {
                ConsoleLogStore.shared.log(level: .error, tag: "TUNNEL", message: "Last tunnel error (late): \(err)")
            }
            let status = await VPNExtensionAPI.call(from: vpn.diagnosticManager(), cmd: .status)
            if let stop = status["stopReason"], stop != "none" {
                ConsoleLogStore.shared.log(level: .warning, tag: "TUNNEL", message: "Tunnel stop reason (late): \(stop)")
            }
        }
    }

    /// Keep the screen awake for the entire time the app is in the foreground,
    /// so the device never sleeps while the user is inside the app (not just
    /// during an active VPN session). Idle lock is re-evaluated on the
    /// foreground/background transitions.
    private func updateIdleTimer() {
        let isForeground = UIApplication.shared.applicationState == .active
        Task { @MainActor in
            UIApplication.shared.isIdleTimerDisabled = isForeground
        }
    }

    var copy: AppCopy { AppCopy(language: selectedLanguage ?? .english) }

    var needsLanguageSelection: Bool { selectedLanguage == nil }

    /// Resolves the device-language + region hints for the first-launch
    /// language overlay. Fully LOCAL: device locale + region, no network
    /// (privacy: the device IP is never sent to any geo service).
    func resolveLanguageHints() {
        guard userCountryCode == nil else { return }
        if let region = Locale.current.region?.identifier {
            userCountryCode = region
            ConsoleLogStore.shared.log(level: .info, tag: "LANG", message: "language hint: device region \(region)")
        }
        languageHintsResolving = false
    }

    func choose(_ language: AppLanguage) {
        selectedLanguage = language
        LanguageStore.current = language
        ConsoleLogStore.shared.log(level: .system, tag: "LANG", message: "Interface language updated -> \(language.title)")
    }

    /// Local metadata only (no TCP ping here): every port-22 SYN counts
    /// against the VPS per-source rate limiter (~6/30s), so SYNs are spent
    /// ONLY on real SSH connects plus the slow ping loop.
    /// Ping freshness comes from the load-time sweep, the minutely
    /// selected-only tick and the list view. Country/flag come from the
    /// OFFLINE on-device resolver (bundled prefix table, no network):
    /// every placed server gets a map dot via the calibrated projection.
    func refreshServerMetadata() {
        guard !profile.host.isEmpty else {
            serverCountry = ""
            serverCountryCode = ""
            serverFlag = "🌐"
            serverCity = ""
            serverPingMs = nil
            hasServerGeo = false
            return
        }

        isResolvingMetadata = true
        let currentHost = profile.host
        let currentPort = profile.port

        ConsoleLogStore.shared.log(level: .info, tag: "PROBE", message: "Analyzing remote server \(currentHost):\(currentPort)...")

        Task {
            // Offline only: LAN badge for private addresses, country from
            // the bundled prefix table otherwise (system DNS at most, never
            // a geo HTTP service — misses simply retry next time).
            let geo: ServerGeoInfo? = (lastGeoHost == currentHost) ? nil : await ServerMetadataResolver.resolveGeo(host: currentHost)

            await MainActor.run {
                guard self.profile.host == currentHost else { return }

                if let geo = geo {
                    self.lastGeoHost = currentHost
                    self.serverCountry = geo.country
                    self.serverCountryCode = geo.countryCode
                    self.serverFlag = geo.flag
                    self.serverCity = geo.city
                    self.serverLatitude = geo.lat
                    self.serverLongitude = geo.lon
                    // Any placed server (LAN or offline country) carries a
                    // real position for the map dot.
                    self.hasServerGeo = true
                    if self.serverName.isEmpty || self.serverName == "My VPS" || self.serverName == currentHost {
                        self.serverName = "\(geo.flag) \(geo.country)"
                    }
                    ConsoleLogStore.shared.log(level: .success, tag: "GEOIP", message: "GeoIP located (offline): \(geo.flag) \(geo.country) (\(geo.city)) [\(geo.lat), \(geo.lon)]")
                } else {
                    // Unresolvable host: show the hostname honestly
                    // instead of a guessed country.
                    self.serverCountry = ""
                    self.serverCountryCode = ""
                    self.serverFlag = "🌐"
                    self.serverCity = ""
                    self.hasServerGeo = false
                }
                self.isResolvingMetadata = false
            }
        }
    }

    /// Fetch ping for all servers in the list (runs in background,
    /// populates per-server caches). Called on every server-list load.
    /// Geo is offline on-device (bundled table); remote servers get
    /// country badges + map dots with no network.
    func refreshAllServerMetadata() {
        let targets = servers
        guard !targets.isEmpty else { return }
        Task {
            var geoResults: [String: ServerGeoInfo] = [:]
            var pingResults: [String: Int] = [:]
            await withTaskGroup(of: (String, ServerGeoInfo?, Int?).self) { group in
                for server in targets {
                    group.addTask {
                        // Ping FIRST (user-visible badge); offline GeoIP next.
                        let ping = await ServerMetadataResolver.measurePing(host: server.host, port: server.port)
                        // Offline table — never leaves the device.
                        let geo = await ServerMetadataResolver.resolveGeo(host: server.host)
                        return (server.id, geo, ping)
                    }
                }
                for await (id, geo, ping) in group {
                    if let geo { geoResults[id] = geo }
                    if let ping { pingResults[id] = ping }
                }
            }
            self.serverGeoCache = geoResults
            self.serverPingCache = pingResults
            self.lastSweepAt = Date()
        }
    }

    /// Minutely ping-only refresh for every server (cheap; offline GeoIP
    /// is cached from load and never re-fetched here).
    /// Keeps list pings and map dot colors live. No-op when the list is empty.
    func refreshAllServerPings() {
        let targets = servers
        guard !targets.isEmpty else { return }
        lastSweepAt = Date()
        let names = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, "\($0.host):\($0.port)") })
        Task {
            var pings: [String: Int] = [:]
            await withTaskGroup(of: (String, Int?).self) { group in
                for server in targets {
                    group.addTask { [pingBudget] in
                        // Budgeted: skip (keep last cached value) instead of
                        // feeding the VPS rate limiter.
                        guard pingBudget.allow() else {
                            ConsoleLogStore.shared.log(level: .info, tag: "PING", message: "skipped for \(server.host):\(server.port) (budget) — keeping last known")
                            return (server.id, nil as Int?)
                        }
                        return (server.id, await ServerMetadataResolver.measurePing(host: server.host, port: server.port))
                    }
                }
                for await (id, ping) in group {
                    if let ping {
                        pings[id] = ping
                        ConsoleLogStore.shared.log(level: .success, tag: "PING", message: "TCP RTT latency: \(ping) ms to \(names[id] ?? id)")
                    } else {
                        ConsoleLogStore.shared.log(level: .warning, tag: "PING", message: "TCP ping probe timed out for \(names[id] ?? id)")
                    }
                }
            }
            self.serverPingCache = pings
            if let sel = self.selectedServer?.id, let ms = pings[sel] {
                self.serverPingMs = ms
            }
        }
    }

    /// When the last full-list sweep ran. The list view skips its appear
    /// sweep when the boot sweep is still fresh — otherwise two sweeps race
    /// at launch and burn the SYN budget twice for the same badges.
    private var lastSweepAt: Date?

    /// Full-list sweep, but only when the previous one is older than `ttl`
    /// (prevents boot-sweep + appear-sweep double spend).
    func refreshAllServerPingsIfStale(ttl: TimeInterval = 60) {
        if let last = lastSweepAt, Date().timeIntervalSince(last) < ttl { return }
        refreshAllServerPings()
    }

    /// Starts the 60s ping loop. Burns minimal SYNs (the VPS rate-limits
    /// port 22 to ~5/min per source): every tick pings only the selected
    /// server, every 3rd tick sweeps the whole list for map/list freshness.
    private var pingTickCount = 0
    private func startServerPingTimer() {
        serverPingTimer?.invalidate()
        serverPingTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pingTickCount += 1
                if self.pingTickCount % 3 == 0 {
                    self.refreshAllServerPings()
                } else {
                    self.refreshSelectedPing()
                }
                self.checkPacketFlowStall()
            }
        }
    }

    /// One SYN for the selected server only (list/map freshness for others
    /// comes from the 3rd-tick sweep + load-time metadata).
    private func refreshSelectedPing() {
        guard let selected = selectedServer else { return }
        guard pingBudget.allow() else { return }
        Task {
            if let ms = await ServerMetadataResolver.measurePing(host: selected.host, port: selected.port) {
                self.serverPingMs = ms
                var cache = self.serverPingCache
                cache[selected.id] = ms
                self.serverPingCache = cache
            }
        }
    }

    /// Stall watchdog: runs on the minutely tick. The ping above guarantees
    /// fresh utun traffic whenever servers exist, so a frozen counter across
    /// two ticks while connected proves the packet flow stalled (e.g. a
    /// missed wake after device sleep). Heals by restarting the tunnel once;
    /// the old tunnel's goodbye disconnect is expected (stallRestartArmed).
    private func checkPacketFlowStall() {
        guard connection == .connected, !servers.isEmpty else {
            stallFrozenCycles = 0
            return
        }
        Task { @MainActor [weak self] in
            guard let self, self.connection == .connected, !self.servers.isEmpty else { return }
            let status = await VPNExtensionAPI.call(from: self.vpn.diagnosticManager(), cmd: .status, timeout: 2)
            guard self.connection == .connected else { return }
            let read = status["packetsRead"].flatMap(Int.init)
            let ago = status["lastReadAgo"] ?? "?"
            let proto = status["proto"] ?? "?"
            if let read, let last = self.lastStallRead {
                let delta = read - last
                // Minutely heartbeat: continuous liveness trace of the packet
                // flow (the +12s counters only cover post-connect).
                ConsoleLogStore.shared.log(level: .info, tag: "TUNNEL", message: "utun heartbeat read=\(read) (+\(delta)/60s) lastReadAgo=\(ago) proto[\(proto)]")
                if read == last {
                    self.stallFrozenCycles += 1
                } else {
                    self.stallFrozenCycles = 0
                }
            } else {
                self.stallFrozenCycles = 0
            }
            self.lastStallRead = read
            guard self.stallFrozenCycles >= 2, !self.stallRestartArmed else { return }
            self.stallRestartArmed = true
            self.stallFrozenCycles = 0
            ConsoleLogStore.shared.log(level: .warning, tag: "STALL", message: "packet flow frozen (utun read=\(read.map(String.init) ?? "?"), lastReadAgo=\(ago)) across minutely checks while connected — restarting tunnel")
            self.vpn.stop()
            try? await Task.sleep(for: .seconds(2))
            guard self.connection == .connected else { self.stallRestartArmed = false; return }
            self.beginConnection()
        }
    }

    func connect(manual: Bool = true) {
        // Kill-switch bookkeeping: a manual connect is user intent; the
        // redial after an unexpected drop only fires while this stays true.
        userIntentConnected = true
        killSwitchAttempts = 0
        // Fresh USER intent re-arms the circuit breaker. A kill-switch
        // redial passes manual:false — the storm it belongs to is exactly
        // what the breaker is counting, so it must not reset the count.
        if manual { breaker.reset() }
        // A fresh manual attempt drives its own lifecycle via real status
        // events (didInvokeStart) — it is no longer the adopted tunnel.
        adoptedLiveTunnel = false
        // Re-entrancy guard: a second tap (same runloop or impatient finger)
        // must never stack another tunnel attempt on top of a live one.
        switch connection {
        case .disconnected, .failed:
            break
        default:
            ConsoleLogStore.shared.log(level: .warning, tag: "CONNECT", message: "Connect tapped while already \(connection) — ignored")
            return
        }
        guard let selected = selectedServer else {
            ConsoleLogStore.shared.log(level: .error, tag: "CONNECT", message: "No server selected")
            return
        }
        // Free-tier gate: no opens > 0 → no tunnel. Unlimited users always
        // have budget (`allowsConnection`). First-use grant BEFORE the gate:
        // the free hour starts on the first Connect tap, never on install.
        // Then re-read the shared ledger so an expiry caught by the kernel
        // (or a purchase made elsewhere) is reflected here without a
        // failed-connect flash. This is the ONLY
        // place the app re-reads the countdown outside launch — after that the
        // UI runs its own in-memory countdown until the next connect tap.
        ensureInitialGrant()
        reloadQuota()
        guard quota.allowsConnection(now: Date()) else {
            ConsoleLogStore.shared.log(level: .error, tag: "QUOTA", message: "Connect blocked: free time exhausted — watch an ad to earn +3h")
            connection = .failed("freeTimeExhausted")
            return
        }
        ConsoleLogStore.shared.log(level: .system, tag: "CONNECT", message: "Starting VPN connection to \(selected.host):\(selected.port) user=\(selected.username)...")
        let mgr = vpn.diagnosticSnapshot()
        ConsoleLogStore.shared.log(level: .info, tag: "VPN", message: "manager hasManager=\(mgr.hasManager) onDemandEnabled=\(mgr.onDemandEnabled) onDemandRules=\(mgr.onDemandRuleCount)")
        if selected.hasPrivateKey {
            ConsoleLogStore.shared.log(level: .ssh, tag: "AUTH", message: "Using Ed25519 private key authentication")
        } else if selected.hasPassword {
            ConsoleLogStore.shared.log(level: .ssh, tag: "AUTH", message: "Using password authentication")
        }
        if !selected.hostKey.isEmpty {
            ConsoleLogStore.shared.log(level: .ssh, tag: "HOSTKEY", message: "Verifying pinned host key: \(selected.hostKey)")
        }

        // Persist locally (instant) and best-effort sync to the extension.
        // The credentials reliably reach the extension via providerConfiguration
        // in performConnectionAttempt(); the extension also persists them into
        // its own store on every startTunnel.
        do { try saveServer(selected) } catch { connection = .failed(error.localizedDescription); return }
        connection = .connecting
        // No TCP probe here: performConnectionAttempt() already gates every
        // attempt with exactly one ping. Probing twice per tap burns SYNs and
        // trips the VPS per-source rate limiter (~5/min) — the outage above.
        // The user may have cancelled while resolving — beginConnection re-checks.
        beginConnection()
    }

    /// Starts the actual tunnel after the selected server is guaranteed to be
    /// persisted locally (extension sync is best-effort in the background).
    private func beginConnection() {
        _ = automation.beginConnect()
        connection = .connecting
        attemptStartedAt = Date()
        startPhasePolling()
        // Resolve server IP upfront so extension doesn't block on DNS during startTunnel
        // (prevents early-death flake where iOS kills the extension for slow launch).
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let selected = self.selectedServer {
                if let resolved = try? SSHEndpointResolver.resolve(selected.host),
                   let ipv4 = resolved.ipv4.first {
                    self.cachedServerIPv4 = ipv4
                } else {
                    self.cachedServerIPv4 = nil
                }
            }
            self.performConnectionAttempt()
        }
    }

    /// Resolved IPv4 of the selected server, cached so the extension
    /// can skip DNS and avoid blocking startTunnel.
    private var cachedServerIPv4: String?

    /// True when the in-flight attempt died within seconds of starting — the
    /// first-start flap signature (CONNECTING -> DISCONNECTED with no traffic).
    private func isEarlyDeath() -> Bool {
        guard let t0 = attemptStartedAt else { return false }
        return Date().timeIntervalSince(t0) < 20
    }

    /// Diagnoses an early disconnect and retries when it looks like the
    /// first-start flake (no extension error, tunnel never got going).
    /// The retry reuses the saved configuration — the same path as a manual
    /// second tap, which is exactly what heals the flake. Bounded by
    /// automation.maxRetries; a real config/auth error fails fast instead.
    private func diagnoseEarlyDeathAndMaybeRetry() {
        // Keep .connecting + phase polling alive while diagnosing.
        let elapsed = attemptStartedAt.map { max(0, Int(Date().timeIntervalSince($0))) } ?? -1
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Sequential (not async-let): the manager is non-Sendable, so it
            // must not cross into concurrent child tasks. Short timeouts keep
            // the diagnosis fast.
            let errDict = await VPNExtensionAPI.call(from: self.vpn.diagnosticManager(), cmd: .lastError, timeout: 1.5)
            // User cancelled while diagnosing — never start then.
            guard self.connection == .connecting else { return }
            let statusDict = await VPNExtensionAPI.call(from: self.vpn.diagnosticManager(), cmd: .status, timeout: 1.5)
            guard self.connection == .connecting else { return }
            // Prefer the message channel, but it dies with the extension
            // process (~100ms deaths) — the keychain record survives it.
            let extErr: String? = errDict["error"].flatMap { $0 == "none" ? nil : $0 }
                ?? TunnelLastError.read()
            if let extErr {
                ConsoleLogStore.shared.log(level: .info, tag: "SELFTEST", message: "post-mortem extension error: \(extErr)")
            }
            let phase = statusDict["phase"] ?? "unknown"
            if let extErr, ConnectionErrorClassifier.isFatal(extErr) {
                self.attemptStartedAt = nil
                self.stopPhasePolling()
                self.connection = .failed(extErr)
                ConsoleLogStore.shared.log(level: .error, tag: "FAIL", message: "Fatal config error (no retry): \(extErr)")
                return
            }
            let msg = "tunnel disconnected \(elapsed)s after start (extension phase=\(phase), extError=\(extErr ?? "none"))"
            // Every failed attempt feeds the circuit breaker (transient AND
            // fatal — a doomed password must not hammer either). The breaker
            // returns true exactly once, on the trip.
            let failure = self.automation.reportFailure(msg)
            let breakerTripped = self.breaker.recordFailure()
            switch failure {
            case .transientFailure(let attempt, _):
                ConsoleLogStore.shared.log(level: .warning, tag: "RETRY", message: "Early death (attempt \(attempt))/\(self.automation.maxRetries): \(msg). Retrying in 2s via saved config...")
                try? await Task.sleep(for: .seconds(2))
                guard self.connection == .connecting else { return }
                if self.breaker.tripped {
                    ConsoleLogStore.shared.log(level: .warning, tag: "RETRY", message: "retry parked — circuit breaker tripped (on-demand off, kill switch still on)")
                    return
                }
                self.attemptStartedAt = Date()
                self.performConnectionAttempt()
            case .gaveUpAfterRetries(let m):
                self.attemptStartedAt = nil
                self.stopPhasePolling()
                if breakerTripped { self.tripCircuitBreaker() }
                let final = breakerTripped
                    ? "circuit breaker: connect-on-demand disabled after 10 consecutive failures (kill switch still ON) — tap Connect to retry"
                    : m
                self.connection = .failed(final)
                ConsoleLogStore.shared.log(level: .error, tag: "FAIL", message: "Gave up after \(self.automation.maxRetries) attempts: \(m) (storm \(self.breaker.consecutiveFailures)/10)")
                self.fetchTunnelDiagnostics()
            case .fatalFailure(let m):
                self.attemptStartedAt = nil
                self.stopPhasePolling()
                self.connection = .failed(m)
                ConsoleLogStore.shared.log(level: .error, tag: "FAIL", message: "Fatal config error (no retry): \(m)")
            default:
                break
            }
        }
    }

    /// Polls the extension for its start-up phase while connecting and logs
    /// every transition. This is what reveals HOW FAR startTunnel gets even
    /// when the final disconnect query races with the tunnel's death.
    private func startPhasePolling() {
        stopPhasePolling()
        lastPolledPhase = nil
        reportedLiveErrors = []
        phasePollTask = Task { @MainActor [weak self] in
            while let self, self.connection == .connecting {
                // Sequential: the manager is non-Sendable, so it must not
                // cross into concurrent child tasks. Short timeouts + 250ms
                // cadence still catch fast flaps.
                let status = await VPNExtensionAPI.call(from: self.vpn.diagnosticManager(), cmd: .status, timeout: 1.5)
                if Task.isCancelled { break }
                if let phase = status["phase"], phase != self.lastPolledPhase {
                    let from = self.lastPolledPhase ?? "?"
                    self.lastPolledPhase = phase
                    ConsoleLogStore.shared.log(level: .info, tag: "TUNNEL", message: "Tunnel phase: \(from) -> \(phase)")
                }
                if Task.isCancelled { break }
                let errRsp = await VPNExtensionAPI.call(from: self.vpn.diagnosticManager(), cmd: .lastError, timeout: 1.5)
                if Task.isCancelled { break }
                if let err = errRsp["error"], err != "none", !self.reportedLiveErrors.contains(err) {
                    self.reportedLiveErrors.insert(err)
                    ConsoleLogStore.shared.log(level: .error, tag: "TUNNEL", message: "Tunnel error (live): \(err)")
                }
                // Pull the extension's own detail lines (SSH stages live there).
                if self.settings.enableLogging {
                    await VPNExtensionAPI.fetchLogs(from: self.vpn.diagnosticManager(), timeout: 2)
                }
                if Task.isCancelled { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func stopPhasePolling() {
        phasePollTask?.cancel()
        phasePollTask = nil
    }

    private func performConnectionAttempt() {
        guard !automation.isConnected else { return }
        // Duplicate-start guard: iOS on-demand or a racing redial may already
        // have a start in flight — our model can lag the real NE state.
        // Stacking another startTunnel on top murders the in-flight SSH
        // handshake, and the retry loop then murders its own replacement
        // forever (connect storm). The live manager status is the truth.
        if let st = self.vpn.liveStatus(),
           st == .connecting || st == .connected || st == .reasserting {
            ConsoleLogStore.shared.log(level: .warning, tag: "RETRY",
                message: "start already \(String(describing: st)) system-side — skipping duplicate startTunnel (would murder the in-flight handshake)")
            return
        }
        var effectiveProfile = profile
        // Only VALID custom DNS entries reach the tunnel: a typo'd upstream
        // silently blackholes every lookup (the relay forwards raw IPs, no
        // fallback). Invalid ones are logged and dropped.
        let rawDNS = settings.resolvedDNSServers
        let dns = settings.validatedDNSServers
        if rawDNS.count != dns.count {
            ConsoleLogStore.shared.log(level: .warning, tag: "DNS",
                message: "ignoring invalid custom DNS entries (kept \(dns.count)/\(rawDNS.count): \(dns.isEmpty ? "none valid — falling back to 8.8.8.8" : dns.joined(separator: ", ")))")
        }
        effectiveProfile.dnsServers = dns
        // Provider profile carries ONLY the user's own rules (a handful of
        // entries, bytes). Curated lists (thousands of domains, ~1MB+ JSON)
        // must NEVER enter providerConfiguration: iOS rejects the whole
        // save past 512KB ("configuration is too large") and the tunnel
        // never starts. Curated domains are pushed over the live
        // sendProviderMessage channel right after connect instead
        // (see pushFullDNSRulesAfterConnect).
        effectiveProfile.dnsRules = DNSBlocklistEntry.encodeList(settings.dnsRules) ?? "[]"
        // Capture pre-resolved IP for this attempt (avoids blocking DNS in extension).
        let serverIP = cachedServerIPv4

        // No app-side TCP ping gate: the SSH connect itself IS the probe
        // (extension has a 10s connect timeout), and every extra port-22 SYN
        // feeds the VPS per-source rate limiter. One tap = one SSH SYN.
        ConsoleLogStore.shared.log(level: .info, tag: "DNS",
            message: "tunnel will use DNS: \(dns.isEmpty ? "8.8.8.8 (default)" : dns.joined(separator: ", ")) + \(settings.dnsRules.count) custom rule(s) in profile\(curatedDomainCount > 0 ? " + \(curatedDomainCount) curated domain(s) pushed live after connect" : "")")
        self.vpn.start(profile: effectiveProfile, serverIP: serverIP,
                       onDemandEnabled: settings.connectOnDemand) { [weak self] error in
            guard let self = self else { return }
            if let error {
                let message = error.localizedDescription
                let failure = self.automation.reportFailure(error)
                let breakerTripped = self.breaker.recordFailure()
                switch failure {
                case .transientFailure(let attempt, _):
                    ConsoleLogStore.shared.log(level: .warning, tag: "RETRY", message: "Transient failure (attempt \(attempt))/\(self.automation.maxRetries): \(message). Retrying in 2s...")
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        // A user cancel (or anything else that left .connecting)
                        // during the backoff kills the retry chain here — a stale
                        // retry must never resurrect the tunnel on its own.
                        guard self.connection == .connecting else {
                            ConsoleLogStore.shared.log(level: .info, tag: "RETRY", message: "retry dropped — connection no longer in progress (cancelled?)")
                            return
                        }
                        if self.breaker.tripped {
                            ConsoleLogStore.shared.log(level: .warning, tag: "RETRY", message: "retry parked — circuit breaker tripped (on-demand off, kill switch still on)")
                            return
                        }
                        self.performConnectionAttempt()
                    }
                case .gaveUpAfterRetries(let msg):
                    if breakerTripped { self.tripCircuitBreaker() }
                    let final = breakerTripped
                        ? "circuit breaker: connect-on-demand disabled after 10 consecutive failures (kill switch still ON) — tap Connect to retry"
                        : msg
                    self.connection = .failed(final)
                    ConsoleLogStore.shared.log(level: .error, tag: "FAIL", message: "Gave up after \(self.automation.maxRetries) attempts: \(msg) (storm \(self.breaker.consecutiveFailures)/10)")
                case .fatalFailure(let msg):
                    self.connection = .failed(msg)
                    ConsoleLogStore.shared.log(level: .error, tag: "FAIL", message: "Fatal config error (no retry): \(msg)")
                default:
                    break
                }
            } else {
                ConsoleLogStore.shared.log(level: .info, tag: "TUNNEL", message: "startVPNTunnel invoked; awaiting NEVPNStatusDidChange")
            }
        }
    }

    func disconnect() {
        // Idempotent: double-taps collapse into a single stop.
        switch connection {
        case .connected:
            ConsoleLogStore.shared.log(level: .system, tag: "DISCONN", message: "User requested VPN disconnect. Closing SSH2 tunnel...")
        case .connecting:
            // Cancel BEFORE the tunnel came up: same teardown, different log
            // line (the extension unwinds its in-flight start instead of
            // finishing a tunnel the user no longer wants).
            ConsoleLogStore.shared.log(level: .system, tag: "DISCONN", message: "User cancelled mid-connect. Aborting tunnel start and closing SSH2...")
        default:
            return
        }
        _ = automation.markDisconnected()
        // Manual disconnect = user no longer wants the tunnel: kill-switch
        // redial must NOT fire after this.
        userIntentConnected = false
        adoptedLiveTunnel = false
        killSwitchAttempts = 0
        breaker.reset()
        connection = .disconnected
        attemptStartedAt = nil
        stallRestartArmed = false
        stallFrozenCycles = 0
        stopPhasePolling()
        stopStatsPolling()
        vpn.stop()
    }

    func tickConnectionTimer() {
        objectWillChange.send()
        automation.tick()
        // Countdown runs in memory: the ledger was read at launch (and again
        // on every connect); `remaining(now:)` decays against the wall clock,
        // so NOTHING is polled here — the kernel keychain is left alone.
    }

    // MARK: - 1s display timer (owned here so it can self-invalidate)

    private var displayTimer: Timer?

    /// Keeps the 1s tick running while anything time-based is on screen:
    /// a live session, the post-disconnect stats window, OR the free-quota countdown
    /// (which decays every second whether the tunnel is up or not). Stops
    /// itself once none applies so we never burn a wakeup when idle+unlimited.
    func startDisplayTimerIfNeeded() {
        let quotaTicking = !quota.isUnlimited && quota.remaining(now: Date()) > 0
        guard connection == .connected || consoleGraceActive || quotaTicking else {
            stopDisplayTimer()
            return
        }
        guard displayTimer == nil else { return }
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            // Timer runs on the main run loop: assert the main actor, then
            // do the model tick entirely on it.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tickConnectionTimer()
                let stillQuota = !self.quota.isUnlimited && self.quota.remaining(now: Date()) > 0
                if self.connection != .connected && !self.consoleGraceActive && !stillQuota {
                    self.stopDisplayTimer()
                }
            }
        }
    }

    func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    // MARK: - Post-disconnect stats window

    /// True for 2 minutes after the last session ended, so the 1s stats
    /// tick keeps running right after a disconnect.
    private func updateConsoleGrace(previous: ConnectionPresentation) {
        let wasActive: Bool
        switch previous {
        case .connecting, .connected: wasActive = true
        case .disconnected, .failed: wasActive = false
        }
        switch connection {
        case .connecting, .connected:
            lastDisconnectAt = nil
        case .disconnected, .failed:
            if wasActive { lastDisconnectAt = Date() }
        }
    }

    /// 2-minute window after a disconnect during which the stats tick stays
    /// alive.
    var consoleGraceActive: Bool {
        guard let t = lastDisconnectAt else { return false }
        return Date().timeIntervalSince(t) < 120
    }

    /// Single source of truth for the floating console button + sidebar:
    /// visible whenever logging is enabled — no connection-state gating, so
    /// the panel is equally discoverable before, during and after a session
    /// (and identical for every user, including App Review).
    var showConsoleButton: Bool {
        settings.enableLogging
    }

    var connectionActiveSeconds: Int { automation.activeSeconds }

    /// Bridge for views (Diagnostics): the live manager for extension
    /// message-channel calls. Read-only — no connection mutation from UI.
    var extensionManager: NETunnelProviderManager? { vpn.diagnosticManager() }

    // MARK: - Local DNS rules management (settings screen)

    /// Adds a local DNS rule after validating it, or replaces an existing
    /// rule when `replacing` is given (edit mode). Returns a localized
    /// error message on failure (nil = saved).
    @discardableResult
    func addDNSRule(domain: String, kind: DNSBlocklistEntry.Kind, ip: String,
                    includeSubdomains: Bool = true,
                    replacing: DNSBlocklistEntry? = nil) -> String? {
        guard LocalDNSFilter.isValidDomain(domain) else { return copy.text(.dnsInvalidDomain) }
        let normalized = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Duplicate check ignores the rule being replaced (editing itself).
        if settings.dnsRules.contains(where: { $0.domain == normalized && $0.id != replacing?.id }) {
            return copy.text(.dnsDuplicateRule)
        }
        if kind == .override {
            guard DNSWire.ipv4Bytes(ip) != nil else { return copy.text(.dnsInvalidIP) }
        }
        let newRule = DNSBlocklistEntry(domain: normalized, kind: kind,
                                        ip: kind == .override ? ip : "",
                                        includeSubdomains: includeSubdomains)
        if let replacing, let idx = settings.dnsRules.firstIndex(where: { $0.id == replacing.id }) {
            settings.dnsRules[idx] = newRule
            ConsoleLogStore.shared.log(level: .info, tag: "DNSFILTER",
                message: "local rule updated: \(normalized)\(includeSubdomains ? " (+subdomains)" : "") -> \(kind == .block ? "0.0.0.0" : ip)")
        } else {
            settings.dnsRules.append(newRule)
            ConsoleLogStore.shared.log(level: .info, tag: "DNSFILTER",
                message: "local rule added: \(normalized)\(includeSubdomains ? " (+subdomains)" : "") -> \(kind == .block ? "0.0.0.0" : ip)")
        }
        pushDNSRulesLive()
        return nil
    }

    func removeDNSRule(id: UUID) {
        settings.dnsRules.removeAll { $0.id == id }
        pushDNSRulesLive()
    }

    /// If the tunnel is running, hand the new ruleset to the extension now so
    /// a block/override applies immediately (no reconnect needed). This was
    /// the long-standing gap: rules only took effect on the next connect, the
    /// browser kept loading before that.
    @MainActor
    private func pushDNSRulesLive() {
        guard connection == .connected else { return }
        pushFullDNSRulesNow()
    }

    /// Pushes custom rules + curated domains over the live message channel in
    /// compact form (domains as plain strings, no per-entry UUID bloat).
    /// Call only while connected — the channel is dead otherwise.
    @MainActor
    private func pushFullDNSRulesNow() {
        let curated = DNSListStore.mergedDomains(subscribedLists)
        VPNExtensionAPI.pushDNSRulesCompact(custom: settings.dnsRules, curatedDomains: curated, to: vpn.diagnosticManager())
    }

    /// Post-connect hook: the system profile carries custom rules only (512KB
    /// iOS cap), so the full set — custom + curated — lands here, seconds
    /// after the tunnel comes up. Called from every path that reaches
    /// .connected (live event + drift-adopted tunnel).
    @MainActor
    private func pushFullDNSRulesAfterConnect() {
        let curated = DNSListStore.mergedDomains(subscribedLists)
        guard !curated.isEmpty else { return }
        VPNExtensionAPI.pushDNSRulesCompact(custom: settings.dnsRules, curatedDomains: curated, to: vpn.diagnosticManager())
        ConsoleLogStore.shared.log(level: .info, tag: "DNSFILTER",
            message: "pushed \(curated.count) curated domain(s) live (\(settings.dnsRules.count) custom) — active now, no reconnect needed")
    }

    // MARK: - Curated hosts lists (AdAway-style subscriptions)

    /// Persisted curated-list subscriptions (downloads + parse results).
    @Published var subscribedLists: [SubscribedDNSList] = DNSListStore.load() {
        didSet { DNSListStore.save(subscribedLists) }
    }
    /// Per-source download state for the UI (spinner / error chips).
    @Published var listRefreshState: [String: String] = [:]

    /// Total domains blocked across subscribed curated lists (deduped).
    var curatedDomainCount: Int {
        DNSListStore.mergedDomains(subscribedLists).count
    }

    /// True when `source` is currently subscribed.
    func isSubscribed(_ source: DNSListSource) -> Bool {
        subscribedLists.contains { $0.sourceID == source.id }
    }

    /// Subscribes (downloads the list for the first time) or unsubscribes.
    /// Any failure surfaces a short localized error chip, never an alert.
    func toggleListSubscription(_ source: DNSListSource) {
        if isSubscribed(source) {
            subscribedLists.removeAll { $0.sourceID == source.id }
            listRefreshState[source.id] = nil
            ConsoleLogStore.shared.log(level: .info, tag: "DNSLIST",
                message: "unsubscribed from curated list \(source.name) (\(source.id))")
            pushDNSRulesLive()
            return
        }
        refreshList(source)
    }

    /// Downloads/updates one curated list. On success the parsed domains
    /// replace the previous copy for that source (idempotent refresh).
    func refreshList(_ source: DNSListSource) {
        guard listRefreshState[source.id] != "loading" else { return }
        listRefreshState[source.id] = "loading"
        ConsoleLogStore.shared.log(level: .info, tag: "DNSLIST", message: "fetching curated list \(source.name): \(source.url)")
        Task { @MainActor in
            do {
                let (data, _) = try await URLSession.shared.data(from: URL(string: source.url)!)
                let text = String(data: data, encoding: .utf8)
                    ?? String(decoding: data, as: UTF8.self)
                let domains = DNSListStore.parseHosts(text)
                guard !domains.isEmpty else {
                    self.listRefreshState[source.id] = "empty"
                    ConsoleLogStore.shared.log(level: .warning, tag: "DNSLIST",
                        message: "curated list \(source.name) parsed 0 domains — kept as-is")
                    return
                }
                // Replace-or-append the source's entry.
                var lists = self.subscribedLists.filter { $0.sourceID != source.id }
                lists.append(SubscribedDNSList(sourceID: source.id, updatedAt: Date(), domains: domains))
                self.subscribedLists = lists
                self.listRefreshState[source.id] = nil
                ConsoleLogStore.shared.log(level: .success, tag: "DNSLIST",
                    message: "curated list \(source.name) loaded: \(domains.count) domains (total curated \(self.curatedDomainCount))")
                self.pushDNSRulesLive()
            } catch {
                self.listRefreshState[source.id] = "failed"
                ConsoleLogStore.shared.log(level: .error, tag: "DNSLIST",
                    message: "curated list \(source.name) fetch failed: \(error.localizedDescription)")
            }
        }
    }

    /// Refreshes every subscribed list (manual pull or launch check).
    func refreshAllSubscribedLists() {
        let ids = DNSListStore.subscribedIDs(subscribedLists)
        for source in DNSListCatalog.all where ids.contains(source.id) {
            refreshList(source)
        }
    }

    /// Localized, actionable message for a failed private-key import.
    func keyImportErrorMessage(_ issue: SSHPrivateKeyImporter.ImportError) -> String {
        switch issue {
        case .empty: return copy.text(.keyImportEmpty)
        case .encryptedKeyUnsupported: return copy.text(.keyImportEncrypted)
        case .unsupportedAlgorithm, .unsupportedFormat: return copy.text(.keyImportUnsupported)
        case .malformedKey: return copy.text(.keyImportMalformed)
        }
    }

    /// Localized message for a failed pinned-host-key entry validation.
    /// Title prefix + reason keeps the alert self-explanatory in every locale.
    func hostKeyErrorMessage(_ reason: HostKeyInvalidReason) -> String {
        let title = copy.text(.hostKeyErrTitle)
        let body: String
        switch reason {
        case .multiLine: body = copy.text(.hostKeyErrMultiLine)
        case .invisibleScalars: body = copy.text(.hostKeyErrInvisible)
        case .expectedFormat: body = copy.text(.hostKeyErrExpectedFormat)
        case .unknownType(let t): body = copy.text(.hostKeyErrUnknownType, substitute: t)
        case .badBase64: body = copy.text(.hostKeyErrBadBase64)
        }
        return "\(title): \(body)"
    }

    /// Applies a hosts-file import: merge (dedupe by domain, imported wins on
    /// conflict) or replace-all. Custom curated-list domains stay separate —
    /// only the user's own rules live in settings.dnsRules.
    func applyImportedRules(_ entries: [DNSBlocklistEntry], replace: Bool) {
        guard !entries.isEmpty else { return }
        if replace {
            settings.dnsRules = entries
        } else {
            var byDomain = Dictionary(settings.dnsRules.map { ($0.domain, $0) }, uniquingKeysWith: { a, _ in a })
            for e in entries { byDomain[e.domain] = e }
            settings.dnsRules = byDomain.values.map { $0 }
        }
        ConsoleLogStore.shared.log(level: .success, tag: "DNSFILTER",
            message: "hosts import \(replace ? "replaced" : "merged") \(entries.count) rule(s) — now \(settings.dnsRules.count) custom rule(s)")
        pushDNSRulesLive()
    }

    // MARK: - Live tunnel stats + usage budget

    /// Issues the initial free hour on FIRST USE (first Connect tap or
    /// first rewarded ad — never on install). Idempotent: withInitialGrant
    /// is a no-op once any expiry exists. Persisted at once so the
    /// extension gate honors it even for tunnels started from Settings.
    func ensureInitialGrant() {
        let store = QuotaLedgerStore()
        let current = store.load()
        guard current.expires == nil, !current.isUnlimited else { return }
        if store.save(current.withInitialGrant(now: Date())) {
            ConsoleLogStore.shared.log(level: .success, tag: "ADS", message: "first-use grant: +1h wall-clock")
        }
    }

    /// Wall-clock seconds of budget remaining right now (0 when unlimited).
    /// Before the first use (no grant yet) shows the full free hour: it is
    /// genuinely available — the next Connect tap issues it.
    var remainingQuotaSeconds: TimeInterval {
        if !quota.isUnlimited, quota.expires == nil { return QuotaLedger.initialGrantSeconds }
        return quota.remaining(now: Date())
    }

    var isUnlimited: Bool { quota.isUnlimited }

    /// StoreKit-localized prices for the paywall buttons. Falls back to the
    /// US round dollars only while the products haven't loaded yet (sandbox
    /// hiccup) — the UI never invents a price: buy() refuses to run without
    /// the real product, so what the button shows is what Apple charges.
    var fullPriceString: String { store.product?.displayPrice ?? "…" }

    /// Normalized [0...1] fraction remaining (for the ring/progress).
    var quotaFraction: Double {
        guard !quota.isUnlimited, let _ = quota.expires else { return 1 }
        let frac = quota.remaining(now: Date()) / QuotaLedger.maxBudgetSeconds
        return min(1, max(0, frac))
    }

    /// Seconds until the rewarded-ad button unlocks (0 = ready to press now).
    /// The bank refills once per hour and is capped at 12h.
    var adCooldownRemaining: TimeInterval {
        guard let last = quota.lastAdView else { return 0 }
        return max(0, QuotaLedger.adCooldownSeconds - Date().timeIntervalSince(last))
    }

    /// True when an ad may be creditable (not unlimited, cooldown over,
    /// bank under the 12h cap, tunnel DOWN so geo targeting is honest).
    var canWatchAd: Bool {
        adsAvailable && !quota.isUnlimited && quota.creditingAdView(now: Date()) != nil && !adPlaying
    }

    /// Reward-credit path for a COMPLETED real rewarded ad only: writes
    /// the ledger, reloads the UI state, logs the outcome. No-ops safely
    /// when the bank is full or the user is unlimited
    /// (creditingAdView == nil). The own-promo fallback never calls this.
    private func creditAdView() {
        let now = Date()
        var ledger = QuotaLedgerStore().load().withInitialGrant(now: now)
        if let credited = ledger.creditingAdView(now: now) {
            ledger = credited
            QuotaLedgerStore().save(ledger)
            reloadQuota()
            ConsoleLogStore.shared.log(level: .success, tag: "ADS", message: "reward credited: +3h wall-clock (expires \(ledger.expires.map { QuotaLedger.formatter.string(from: $0) } ?? "never"))")
        } else {
            ConsoleLogStore.shared.log(level: .warning, tag: "ADS", message: "ad not credited (unlimited or bank full)")
        }
    }

    /// Rewarded ad via AdMob (production unit) — the only ad SDK.
    ///
    /// Geo rule: ads are offered ONLY while the tunnel is down
    /// (adsAvailable gate) — through the tunnel the egress country would
    /// be the server's, skewing the ad network's country targeting. No
    /// own geo lookup is performed: the ad SDK does its own targeting.
    func watchAd() {
        guard canWatchAd else { return }
        adPlaying = true
        ConsoleLogStore.shared.log(level: .info, tag: "ADS", message: "rewarded ad requested (AdMob)")
        Task { @MainActor [weak self] in
            let outcome = await RewardedAdRouter.presentRewarded()
            guard let self else { return }
            self.adPlaying = false
            self.refreshAdvertisingPrivacy()
            switch outcome {
            case .earned:
                break
            case .noFill:
                self.showAdNotice(.adNoFillShort)
            case .dismissedEarly:
                ConsoleLogStore.shared.log(level: .warning, tag: "ADS", message: "reward not earned (dismissed early)")
                self.showAdNotice(.adRewardNotCredited)
            }
            guard outcome == .earned else { return }
            creditAdView()
        }
    }

    /// Shows a short in-button notice (5s) explaining why no reward came.
    func showAdNotice(_ key: CopyKey) {
        adNoticeKey = key
        adNoticeUntil = Date().addingTimeInterval(5)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5.1))
            guard let self, Date() >= self.adNoticeUntil else { return }
            self.adNoticeKey = nil
        }
    }

    /// Re-reads the shared ledger (after an ad view / purchase / app start).
    /// Does NOT grant: the initial hour is issued only by first use
    /// (ensureInitialGrant on Connect, or the ad-credit path).
    func reloadQuota() {
        quota = QuotaLedgerStore().load()
        // The quota countdown may have (re)started ticking — spin the 1s
        // display timer even with the tunnel down so the mm:ss actually
        // decays on screen.
        startDisplayTimerIfNeeded()
    }

    /// Triggered from the Settings Unlimited card or the paywall. Buys
    /// `com.ssh2vpn.unlimited` (full price) or
    /// `com.ssh2vpn.unlimited.discount` (one-time intro offer) and, on
    /// success, sets the shared ledger to unlimited (kernel honors it).
    /// Returns the StoreKit outcome so callers can react to cancellation
    /// (e.g. show the discounted follow-up offer).
    func buyUnlimited(discount: Bool = false) async -> StoreManager.PurchaseOutcome {
        let outcome = await discount ? store.purchaseDiscount() : store.purchaseUnlimited()
        switch outcome {
        case .success:
            reloadQuota()
            ConsoleLogStore.shared.log(level: .success, tag: "IAP",
                                       message: discount ? "unlimited (intro offer) purchased and applied"
                                                          : "unlimited purchased and applied")
        case .failure(let msg):
            ConsoleLogStore.shared.log(level: .error, tag: "IAP", message: "purchase failed: \(msg)")
        case .userCancelled, .pending:
            break
        }
        return outcome
    }

    /// Restore button: re-checks App Store entitlements and, if owned,
    /// re-applies unlimited to the shared ledger.
    @Published var purchaseNotice: String?
    @Published var advertisingPrivacyAvailable = false
    func refreshAdvertisingPrivacy() { advertisingPrivacyAvailable = AdvertisingPrivacy.optionsRequired }
    func restorePurchase() async {
        do {
            try await AppStore.sync()
            let owned = await store.refreshEntitlementClearingIfRevoked()
            reloadQuota()
            purchaseNotice = owned ? copy.text(.purchaseOwned) : copy.text(.restoreError)
        } catch { purchaseNotice = copy.text(.restoreError) }
    }

    /// Polls the extension status every 2s while connected: SSH pool size,
    /// live channels, cumulative byte counters. Drives the stats strip.
    private func startStatsPolling() {
        stopStatsPolling()
        statsPollTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.connection == .connected {
                let status = await VPNExtensionAPI.call(from: self.vpn.diagnosticManager(), cmd: .status, timeout: 2)
                self.sshConnectionCount = Int(status["sshConns"] ?? "") ?? 0
                self.activeChannelCount = Int(status["channels"] ?? "") ?? 0
                self.tunnelUpBytes = Int(status["upBytes"] ?? "") ?? 0
                self.tunnelDownBytes = Int(status["downBytes"] ?? "") ?? 0
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func stopStatsPolling() {
        statsPollTask?.cancel()
        statsPollTask = nil
        sshConnectionCount = 0
        activeChannelCount = 0
        tunnelUpBytes = 0
        tunnelDownBytes = 0
    }
}

struct VPNProfile: Equatable {
    var host: String
    var port: Int
    var username: String
    var password: String
    var privateKey: String
    var hostKey: String
    var dnsServers: [String] = []
    /// Local DNS rules (block/override) — the extension answers these
    /// domains locally, before any upstream query.
    var dnsRules: String = ""
}



private enum SettingsStore {
    nonisolated(unsafe) private static let defaults = UserDefaults(suiteName: "group.com.sshtunnel.shared") ?? .standard

    static func load() -> AppSettingsState {
        guard let data = defaults.data(forKey: AppSettingsCodec.key),
              let decoded = try? AppSettingsCodec.decode(data) else {
            return AppSettingsState()
        }
        return decoded
    }

    static func save(_ settings: AppSettingsState) {
        guard let data = try? AppSettingsCodec.encode(settings) else { return }
        defaults.set(data, forKey: AppSettingsCodec.key)
    }
}

@MainActor
private final class VPNController {
    private let providerBundleIdentifier = "com.ssh2vpn.app.packet-tunnel"
    /// Single reused manager for the whole app. Found via loadAllFromPreferences
    /// (or created once) so we never accumulate duplicate VPN profiles —
    /// there is exactly one profile for this app, re-pointed at whatever server
    /// the user selects.
    private var manager: NETunnelProviderManager?
    /// Generation counter: bumped on every start/stop so a stale creation-wait
    /// from a superseded attempt aborts instead of starting a dead tunnel.
    private var startEpoch = 0
    /// One-time migration flag: legacy cleanup runs exactly once ever, never
    /// on every connect.
    private static let legacyCleanupKey = "ssh2vpn.legacyCleanupDone.v1"
    private static var legacyCleanupDone: Bool {
        get { UserDefaults.standard.bool(forKey: legacyCleanupKey) }
        set { UserDefaults.standard.set(newValue, forKey: legacyCleanupKey) }
    }
    /// Cached on the same assignments as `manager` so the (nonisolated)
    /// status observer can tell our connection apart from stale/foreign
    /// profiles without crossing actor isolation. A stale read only risks
    /// accepting one foreign event — never data corruption.
    nonisolated(unsafe) private var knownConnection: NEVPNConnection?
    /// True once startVPNTunnel has been invoked for the current attempt.
    /// Lets the observer tell a REAL disconnect (something of ours was
    /// running) from STALE churn (prefs reload re-posting DISCONNECTED while
    /// nothing was ever started — this used to clobber .connecting set by a
    /// fresh tap and orphan its whole attempt).
    nonisolated(unsafe) var didInvokeStart = false

    /// Read-only snapshot for diagnostics: stale on-demand rules from older
    /// builds persist on the manager across reconfigures (we never clear
    /// them) and can silently split-tunnel traffic around our default route.
    func diagnosticSnapshot() -> (onDemandEnabled: Bool, onDemandRuleCount: Int, hasManager: Bool) {
        guard let manager else { return (false, 0, false) }
        return (manager.isOnDemandEnabled, manager.onDemandRules?.count ?? 0, true)
    }

    /// Loads (or creates) the single app manager WITHOUT starting the tunnel.
    /// Lets the app talk to the extension over the message channel before a
    /// connection exists.
    func ensureManagerLoaded(completion: @escaping () -> Void) {
        if manager != nil { completion(); return }
        resolveManager { _ in completion() }
    }

    func start(profile: VPNProfile, serverIP: String?, completion: @escaping (Error?) -> Void) {
        start(profile: profile, serverIP: serverIP, onDemandEnabled: false, completion: completion)
    }

    func start(profile: VPNProfile, serverIP: String?, onDemandEnabled: Bool, completion: @escaping (Error?) -> Void) {
        // New generation: any creation-wait from an older attempt must die,
        // and its parked completion must never fire. Nothing invoked yet.
        startEpoch += 1
        pendingCreationCompletion = nil
        didInvokeStart = false
        let epoch = startEpoch
        // Resolve (deduplicate) the single app profile before building.
        resolveManager { [weak self] error in
            guard let self else { return }
            guard error == nil else { completion(error); return }
            guard let manager = self.manager else { completion(nil); return }

            // Secrets now come straight from the shared UserDefaults profile,
            // so they survive restarts without any Keychain round-trip dance.
            let password = profile.password
            let privateKey = profile.privateKey

            let profileInput = VPNProfileInput(
                host: profile.host,
                port: profile.port,
                username: profile.username,
                password: password,
                privateKey: privateKey,
                hostKey: profile.hostKey,
                dnsServers: profile.dnsServers
            )

            let configuration: VPNConfiguration
            do {
                configuration = try VPNConfigurationBuilder.build(
                    profile: profileInput,
                    providerBundleIdentifier: self.providerBundleIdentifier
                )
            } catch {
                completion(error)
                return
            }

            let configurationProtocol = NETunnelProviderProtocol()
            configurationProtocol.providerBundleIdentifier = self.providerBundleIdentifier
            configurationProtocol.serverAddress = configuration.serverAddress
            configurationProtocol.enforceRoutes = configuration.enforceRoutes
            // includeAllNetworks ON: per Apple docs, without it the system
            // routes only "designated system services" (DNS, some system
            // traffic) through the tunnel while app TCP bypasses it — our
            // delta=0 signature. The old Code=1 fear predates the
            // save→reload→start fix; a Code=1 now surfaces via automation.
            configurationProtocol.includeAllNetworks = configuration.includeAllNetworks

            var providerConfig = configuration.providerConfiguration
            let credentialID = ServerSecrets.account(host: profile.host, port: profile.port, username: profile.username)
            do {
                let secrets = ServerSecrets(password: password.isEmpty ? nil : password, privateKey: privateKey.isEmpty ? nil : privateKey)
                try KeychainCredentialVault().write(JSONEncoder().encode(secrets), account: credentialID)
            } catch { completion(error); return }
            providerConfig["credentialID"] = credentialID
            // Pre-resolved server IPv4 (avoids blocking DNS in extension startTunnel,
            // which caused early-death flake where iOS killed the extension for slow launch).
            if let serverIP {
                providerConfig["serverIP"] = serverIP
            }
            // Local DNS rules (block/override): the extension answers these
            // domains locally before any upstream query (JSON-encoded list).
            // PROFILE CARRIES CUSTOM RULES ONLY (see performConnectionAttempt).
            // Hard size guard: iOS rejects saves past 512KB, so anything
            // above 200KB of rules is dropped from the profile instead of
            // killing the whole connect — the full set is pushed live after
            // the tunnel comes up anyway.
            if !profile.dnsRules.isEmpty, profile.dnsRules != "[]" {
                let rulesBytes = profile.dnsRules.utf8.count
                if rulesBytes > 200_000 {
                    ConsoleLogStore.shared.log(level: .error, tag: "DNSFILTER",
                        message: "custom rules too large for VPN profile (\(rulesBytes) bytes) — dropped from profile, will push live after connect")
                } else {
                    providerConfig["dnsRules"] = profile.dnsRules
                }
            }

            // Reuse check: if the stored system configuration already equals
            // the desired one, skip saveToPreferences/loadFromPreferences and
            // start the tunnel directly. Rewriting identical configs only
            // churns NEVPN status and wastes failure surface.
            let desiredSnapshot = VPNProtocolSnapshot(
                providerBundleIdentifier: self.providerBundleIdentifier,
                serverAddress: configuration.serverAddress,
                enforceRoutes: configuration.enforceRoutes,
                includeAllNetworks: configuration.includeAllNetworks,
                isEnabled: true,
                providerConfiguration: providerConfig
            )
            if let live = manager.protocolConfiguration as? NETunnelProviderProtocol {
                let currentSnapshot = VPNProtocolSnapshot(
                    providerBundleIdentifier: live.providerBundleIdentifier ?? "",
                    serverAddress: live.serverAddress ?? "",
                    enforceRoutes: live.enforceRoutes,
                    includeAllNetworks: live.includeAllNetworks,
                    isEnabled: manager.isEnabled,
                    providerConfiguration: live.providerConfiguration ?? [:]
                )
                if VPNConfigComparer.isSame(current: currentSnapshot, desired: desiredSnapshot) {
                    ConsoleLogStore.shared.log(level: .info, tag: "VPN", message: "Reusing existing VPN configuration (unchanged) — starting tunnel directly")
                    self.startTunnelNow(manager: manager, completion: completion)
                    return
                }
            }

            configurationProtocol.providerConfiguration = providerConfig
            manager.protocolConfiguration = configurationProtocol
            manager.localizedDescription = "SSH2VPN"
            manager.isEnabled = true
            // On-demand (Advanced settings): when enabled, the system keeps
            // the tunnel up whenever any network is reachable. Applied on the
            // same save as the rest of the profile so it can never desync.
            Self.applyOnDemandRules(to: manager, enabled: onDemandEnabled)

            // The save callback is @Sendable: expose the non-Sendable locals
            // as unsafe-sendable shadows here (single main-actor Task inside
            // is their only consumer) so the closure captures only the safe
            // shadows.
            nonisolated(unsafe) let sendableCompletion = completion
            nonisolated(unsafe) let sendableManager = manager
            manager.saveToPreferences { [weak self] saveError in
                Task { @MainActor in
                    guard let self else { return }
                    // Save failed (typically: system VPN-consent dialog still
                    // pending on first install) — wait for creation instead of
                    // failing the attempt outright. See waitForProfileCreation.
                    if saveError != nil {
                        self.pendingCreationCompletion = sendableCompletion
                        self.waitForProfileCreation(epoch: epoch, saveError: saveError, budget: RetryBudget())
                        return
                    }
                    // CRITICAL FIX (matches VPNConnectionCoordinator): reload
                    // preferences after save and before start. Without this the
                    // manager's in-memory state can be out of sync with the network
                    // extension, producing NEVPNErrorDomain Code=1.
                    self.reloadAndStart(manager: sendableManager, completion: sendableCompletion)
                }
            }
        }
    }

    /// Reloads preferences after a save (keeps the manager in sync with the
    /// network extension — otherwise NEVPNErrorDomain Code=1) and starts.
    /// MainActor: owns didInvokeStart; the completion callback hops back to
    /// the main actor before firing so no non-Sendable value crosses
    /// isolation domains.
    private func reloadAndStart(manager: NETunnelProviderManager, completion: @escaping (Error?) -> Void) {
        nonisolated(unsafe) let sendableCompletion = completion
        nonisolated(unsafe) let sendableManager = manager
        manager.loadFromPreferences { [weak self] reloadError in
            // Single main-actor Task is the only consumer of the shadows.
            Task { @MainActor in
                guard let self else {
                    sendableCompletion(reloadError)
                    return
                }
                guard reloadError == nil else { sendableCompletion(reloadError); return }
                self.didInvokeStart = true
                do {
                    try sendableManager.connection.startVPNTunnel()
                    sendableCompletion(nil)
                } catch {
                    sendableCompletion(error)
                }
            }
        }
    }

    /// Completion parked while waiting for profile creation. MainActor-owned
    /// so async ticks can reacquire it without moving non-Sendable values
    /// (manager/completion) across isolation domains. Cleared on every new
    /// start/stop so a superseded wait never fires a stale completion.
    private var pendingCreationCompletion: ((Error?) -> Void)?

    /// True for save errors no retry can heal: the iOS 512KB profile cap
    /// ("too large" / "maximum size") or a rejected configuration. These
    /// must surface immediately instead of burning the 2-minute wait.
    private static func isDeterministicSaveError(_ error: Error?) -> Bool {
        guard let error else { return false }
        let text = error.localizedDescription.lowercased()
        return text.contains("too large") || text.contains("maximum size") || text.contains("invalid")
    }

    /// Waits for a freshly saved VPN profile to become creatable: retries the
    /// save every 5 seconds for up to 2 minutes (first install: the system
    /// consent dialog may still be pending), then surfaces the last error.
    /// Aborts silently when superseded by a newer start or by stop().
    /// Deterministic errors (oversized/invalid configuration) fail FAST —
    /// retrying them for 2 minutes can never help.
    private func waitForProfileCreation(
        epoch: Int,
        saveError: Error?,
        budget: RetryBudget
    ) {
        if Self.isDeterministicSaveError(saveError) {
            ConsoleLogStore.shared.log(level: .error, tag: "VPN", message: "VPN profile save failed permanently (\(saveError?.localizedDescription ?? "unknown error")) — not retrying")
            guard let completion = pendingCreationCompletion else { return }
            pendingCreationCompletion = nil
            completion(saveError)
            return
        }
        var budget = budget
        guard budget.consume() else {
            ConsoleLogStore.shared.log(level: .error, tag: "VPN", message: "VPN profile was not created within 2 minutes — giving up")
            guard let completion = pendingCreationCompletion else { return }
            pendingCreationCompletion = nil
            completion(saveError)
            return
        }
        if budget.used == 1 {
            ConsoleLogStore.shared.log(level: .warning, tag: "VPN", message: "VPN profile save failed (\(saveError?.localizedDescription ?? "unknown error")) — waiting up to 2 min for creation, retrying every 5s")
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(budget.intervalSeconds))
            guard let self, self.startEpoch == epoch else { return }
            guard let completion = self.pendingCreationCompletion else { return }
            self.pendingCreationCompletion = nil
            guard let manager = self.manager else { completion(saveError); return }
            // RetryBudget is a Sendable value type — a plain copy is enough.
            let sendableBudget = budget
            nonisolated(unsafe) let sendableCompletion = completion
            nonisolated(unsafe) let sendableManager = manager
            manager.saveToPreferences { [weak self] retryError in
                // Non-main callback: hop back before touching controller state.
                Task { @MainActor in
                    guard let self, self.startEpoch == epoch else { return }
                    if retryError == nil {
                        ConsoleLogStore.shared.log(level: .success, tag: "VPN", message: "VPN profile created after waiting")
                        self.reloadAndStart(manager: sendableManager, completion: sendableCompletion)
                    } else {
                        self.waitForProfileCreation(epoch: epoch, saveError: retryError, budget: sendableBudget)
                    }
                }
            }
        }
    }

    /// Starts the tunnel on an already-configured manager (reuse path — the
    /// stored configuration already matches, so no save is needed).
    private func startTunnelNow(manager: NETunnelProviderManager, completion: @escaping (Error?) -> Void) {
        didInvokeStart = true
        do {
            try manager.connection.startVPNTunnel()
            completion(nil)
        } catch {
            completion(error)
        }
    }

    /// Removes every VPN profile owned by this app (matched by provider
    /// bundle id) and forgets the cached manager, so the next connect
    /// recreates the profile from scratch. Used when the system reports
    /// INVALID CONFIGURATION — a wedged profile never heals itself.
    func removeAllProfiles(completion: @escaping () -> Void) {
        nonisolated(unsafe) let sendableCompletion = completion
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            // Non-main system callback: hop to the main actor (owner of
            // manager/knownConnection) before mutating controller state.
            nonisolated(unsafe) let sendableManagers = managers
            Task { @MainActor in
                guard let self else { sendableCompletion(); return }
                let mine = (sendableManagers ?? []).filter {
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.providerBundleIdentifier
                }
                guard !mine.isEmpty else {
                    self.manager = nil
                    self.knownConnection = nil
                    sendableCompletion()
                    return
                }
                let group = DispatchGroup()
                for m in mine {
                    group.enter()
                    m.removeFromPreferences { _ in group.leave() }
                }
                group.notify(queue: .main) { [weak self] in
                    nonisolated(unsafe) let completion = sendableCompletion
                    Task { @MainActor in
                        self?.manager = nil
                        self?.knownConnection = nil
                        completion()
                    }
                }
            }
        }
    }

    /// Sets or clears on-demand rules on the manager. When enabled, the
    /// system auto-connects the tunnel on any reachable network. Never call
    /// while a tunnel is running (apply on the profile save path only).
    private static func applyOnDemandRules(to manager: NETunnelProviderManager, enabled: Bool) {
        if enabled {
            let rule = NEOnDemandRuleConnect()
            rule.interfaceTypeMatch = .any
            manager.onDemandRules = [rule]
            manager.isOnDemandEnabled = true
        } else {
            manager.onDemandRules = []
            manager.isOnDemandEnabled = false
        }
    }

    /// Finds the single existing profile for this app (by provider bundle id)
    /// and reuses it; creates one only if none exists. Any extra duplicate
    /// profiles that were created by earlier versions are removed so we never
    /// end up with several identical VPN profiles.
    private func resolveManager(completion: @escaping (Error?) -> Void) {
        nonisolated(unsafe) let sendableCompletion = completion
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            // Non-main system callback: hop to the main actor before
            // mutating controller state (manager/knownConnection/flags).
            nonisolated(unsafe) let sendableManagers = managers
            Task { @MainActor in
                guard let self = self else { return }
                if error != nil {
                    // A transient load error shouldn't block a first-time create.
                    self.manager = NETunnelProviderManager()
                    self.knownConnection = self.manager?.connection
                    sendableCompletion(nil)
                    return
                }
                let isAppProfile: (NETunnelProviderManager) -> Bool = { m in
                    (m.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.providerBundleIdentifier
                }
                let existing = sendableManagers?.first(where: isAppProfile)
                if let existing {
                    self.manager = existing
                } else {
                    self.manager = NETunnelProviderManager()
                }
                self.knownConnection = self.manager?.connection
                // One-time migration (runs exactly once ever, never on every
                // connect): legacy profiles from the com.sshtunnel era can never
                // connect again (extension bundle id changed) but still post
                // status notifications. Remove them a single time.
                if !Self.legacyCleanupDone {
                    Self.legacyCleanupDone = true
                    let stale = (sendableManagers ?? []).filter {
                        TunnelOwnership.isStaleLegacy(bundleID: ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier)
                    }
                    for s in stale {
                        s.removeFromPreferences { _ in }
                    }
                    if !stale.isEmpty {
                        ConsoleLogStore.shared.log(level: .warning, tag: "VPN", message: "Removed \(stale.count) stale com.sshtunnel VPN profile(s) (one-time migration)")
                    }
                }
                // Delete any leftover duplicates (beyond the first) so the system
                // settings don't accumulate identical app profiles.
                if let sendableManagers {
                    let dupes = sendableManagers.filter(isAppProfile)
                    for dupe in dupes.dropFirst() {
                        dupe.removeFromPreferences { _ in }
                    }
                }
                // Migrate the old system VPN configuration before any new start.
                if let manager = self.manager,
                   let proto = manager.protocolConfiguration as? NETunnelProviderProtocol,
                   var config = proto.providerConfiguration,
                   config["password"] != nil || config["privateKey"] != nil {
                    do {
                        let host = config["host"] as? String ?? ""
                        let port = (config["port"] as? NSNumber)?.intValue ?? 22
                        let username = config["username"] as? String ?? ""
                        let account = ServerSecrets.account(host: host, port: port, username: username)
                        let secrets = ServerSecrets(password: config["password"] as? String, privateKey: config["privateKey"] as? String)
                        try KeychainCredentialVault().write(JSONEncoder().encode(secrets), account: account)
                        config.removeValue(forKey: "password")
                        config.removeValue(forKey: "privateKey")
                        config["credentialID"] = account
                        proto.providerConfiguration = config
                        manager.protocolConfiguration = proto
                        manager.saveToPreferences { error in sendableCompletion(error) }
                    } catch { sendableCompletion(error) }
                    return
                }
                sendableCompletion(nil)
            }
        }
    }

    func stop() {
        startEpoch += 1
        pendingCreationCompletion = nil
        didInvokeStart = false
        // A manual stop must also drop on-demand rules — otherwise the system
        // immediately resurrects the tunnel the user just asked to stop (the
        // classic "VPN turns itself back on" bug). Rules are re-applied on the
        // next connect if the setting is still enabled.
        if let manager, manager.isOnDemandEnabled || !(manager.onDemandRules ?? []).isEmpty {
            manager.onDemandRules = []
            manager.isOnDemandEnabled = false
            manager.saveToPreferences { _ in }
            ConsoleLogStore.shared.log(level: .info, tag: "VPN", message: "on-demand rules cleared by manual disconnect")
        }
        manager?.connection.stopVPNTunnel()
    }

    /// Live NE status of our tunnel (nil before the manager resolves).
    /// Lets callers tell a real in-flight start from a stale model.
    func liveStatus() -> NEVPNStatus? {
        guard let manager else { return nil }
        return manager.connection.status
    }

    /// Clears on-demand rules + disables on-demand on the live manager,
    /// saved to preferences (circuit breaker). Rules are re-applied on the
    /// next connect if the setting is still enabled.
    func clearOnDemandRules() {
        guard let manager, manager.isOnDemandEnabled || !(manager.onDemandRules ?? []).isEmpty else { return }
        manager.onDemandRules = []
        manager.isOnDemandEnabled = false
        manager.saveToPreferences { _ in }
    }

    /// True when this connection object belongs to our manager. Events from
    /// stale/foreign profiles are ignored by the status observer. Accepts
    /// everything while the manager isn't resolved yet (early boot).
    /// Nonisolated on purpose: the observer closure is nonisolated and
    /// NEVPNConnection isn't Sendable.
    nonisolated func owns(_ connection: NEVPNConnection) -> Bool {
        guard let known = knownConnection else { return true }
        return known === connection
    }

    /// Exposes the live VPN manager so the app can talk to the tunnel
    /// extension over the app-message channel (diagnostics, errors).
    func diagnosticManager() -> NETunnelProviderManager? { manager }

    /// The system's own view of the tunnel right now — the ground truth the
    /// UI re-syncs against (model state can drift after missed events).
    /// Nil when the manager isn't loaded yet ("unknown, don't heal").
    func currentSystemStatus() -> NEVPNStatus? {
        manager?.connection.status
    }
}

/// Minimal typed API for the app -> packet-tunnel-extension message channel.
///
/// The extension does not share storage with the app (no app-group), so we
/// exchange data as request/response "function calls" over
/// NETunnelProviderSession.sendProviderMessage. This is the official Apple
/// mechanism and works for any app/extension pair.
enum VPNExtensionAPI {
    enum Cmd: String {
        case status = "status"
        case lastError = "lastError"
        case serverList = "serverList"
        case serverGet = "serverGet"
        case serverSet = "serverSet"
        case serverDelete = "serverDelete"
        case serverSelect = "serverSelect"
        case logs = "logs"
        case dnsRulesSet = "dnsRulesSet"
        /// Compact rules push: custom entries + curated domains as plain
        /// strings (no UUID bloat). Replaces dnsRulesSet for large lists.
        case dnsRulesSetCompact = "dnsRulesSetCompact"
        /// Server-reported egress check (extension runs SSH exec on the live
        /// pool; the phone contacts no third party for it).
        case egressCheck = "egressCheck"
    }

    /// Sends a command (plus optional args) to the extension and returns its
    /// JSON response payload ([String: String]). Empty on any transport error.
    @MainActor
    static func call(
        from manager: NETunnelProviderManager?,
        cmd: Cmd,
        args: [String: Any]? = nil,
        timeout: TimeInterval = 3
    ) async -> [String: String] {
        guard let session = manager?.connection as? NETunnelProviderSession else { return [:] }
        var body: [String: Any] = ["cmd": cmd.rawValue]
        if let args { body["args"] = args }
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        return await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            try? session.sendProviderMessage(data) { response in
                guard resumed.withLock({ if $0 { return false }; $0 = true; return true }) else { return }
                guard let response,
                      let obj = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
                      let payload = obj["data"] as? [String: String] else {
                    continuation.resume(returning: [:])
                    return
                }
                continuation.resume(returning: payload)
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                if resumed.withLock({ if $0 { return false }; $0 = true; return true }) {
                    continuation.resume(returning: [:])
                }
            }
        }
    }

    /// Compact push of the effective ruleset: custom entries (JSON, tiny)
    /// plus curated block domains (plain-string JSON array — ~6x smaller
    /// than entry JSON with UUIDs). The extension merges them in
    /// mergeCompactRules: custom scope wins, curated adds subtree blocks.
    /// Safe to call only while connected.
    @MainActor
    static func pushDNSRulesCompact(custom: [DNSBlocklistEntry], curatedDomains: [String], to manager: NETunnelProviderManager?) {
        let customJSON = DNSBlocklistEntry.encodeList(custom) ?? "[]"
        let curatedJSON: String = {
            guard let data = try? JSONEncoder().encode(curatedDomains) else { return "[]" }
            return String(data: data, encoding: .utf8) ?? "[]"
        }()
        let args: [String: Any] = ["custom": customJSON, "curated": curatedJSON]
        Task {
            _ = await call(from: manager, cmd: .dnsRulesSetCompact, args: args)
        }
    }

    // MARK: - Server list API (extension owns its own copy of the list)

    /// Adds or updates a server in the extension. Secrets are only sent when
    /// the caller explicitly provides them (non-nil).
    @MainActor
    static func saveServer(_ profile: ServerProfile, to manager: NETunnelProviderManager?) async {
        let args = ServerListCoder.encodeServerSet(profile)
        _ = await call(from: manager, cmd: .serverSet, args: args)
    }

    @MainActor
    static func deleteServer(id: String, from manager: NETunnelProviderManager?) async {
        _ = await call(from: manager, cmd: .serverDelete, args: ["id": id])
    }

    @MainActor
    static func selectServer(id: String, from manager: NETunnelProviderManager?) async {
        _ = await call(from: manager, cmd: .serverSelect, args: ["id": id])
    }

    /// Pulls the extension's recent console lines (newest last) and ingests
    /// them into the app log. This is the only tunnel-detail bridge that works
    /// without an app-group. Returns empty when the extension is unreachable.
    @MainActor
    static func fetchLogs(from manager: NETunnelProviderManager?, limit: Int = 200, timeout: TimeInterval = 3) async {
        let d = await call(from: manager, cmd: .logs, args: ["limit": limit], timeout: timeout)
        guard let json = d["entries"],
              let arr = try? JSONDecoder().decode([ConsoleLogEntry].self, from: Data(json.utf8)),
              !arr.isEmpty else { return }
        ConsoleLogStore.shared.ingestExternal(arr)
    }
}

/// Post-connect traffic self-test with ZERO third-party contacts — neither
/// the phone nor the server sends a single packet anywhere for this check.
/// The phone talks only to the user's OWN server here:
///   0. SSH banner check: plain TCP to the server's own port through the
///      system stack (i.e. through the tunnel while VPN is up). A banner
///      proves routing + relay + server reachability in one round trip.
///   1. Egress check: the server reads its OWN routing table over the
///      existing SSH session (extension-side exec — a local `ip route`
///      lookup, no traffic). The reported egress source IP is compared
///      against the server IP: equal means traffic really exits via the VPS.
/// Runs detached (blocking DNS stays off the main thread); results go
/// to the console log. Diagnostic only — never gates the UI state.
enum TunnelSelfTester {
    static func run(expectedHost: String, resolvedIPv4: [String], sshPort: Int = 22,
                    serverReport: SSHExecCheck.Report = SSHExecCheck.Report(),
                    utunReadBefore: Int? = nil) async -> Bool {
        slog(.system, "SELFTEST", "starting post-connect traffic checks (phone contacts only its own server)")
        logSystemPath()
        // Interface table AS THE APP SEES IT: if utun is missing here while
        // the extension sees it, the app's sockets can never use the tunnel.
        slog(.info, "SELFTEST", "app-ifaces [\(LocalInterfaceNets.describeInterfaces().joined(separator: ","))]")
        if let before = utunReadBefore {
            slog(.info, "SELFTEST", "utun read before=\(before)")
        }
        let expected = TunnelSelfTest.pickExpected(host: expectedHost, resolvedIPv4: resolvedIPv4)
        let dialTarget = resolvedIPv4.first ?? expectedHost

        // 0. Banner check against the user's own server (no third party).
        // State machine fully traced: hangs in setup/waiting (no route) look
        // different from instant failed(RST) and from ready-then-stall.
        let banner = await readBanner(host: dialTarget, port: sshPort, timeout: 8) { st in
            slog(.info, "SELFTEST", "banner \(dialTarget):\(sshPort) state=\(st)")
        }
        if let banner {
            slog(.success, "SELFTEST", "server banner OK (\(banner)) — system routes traffic through the tunnel to your server")
        } else {
            slog(.error, "SELFTEST", "server banner FAILED (nil) — system stack can't reach your server; VPN routes likely inactive")
        }

        // 1. Egress IP as reported by the server itself (via SSH exec —
        // the phone asked nobody else). Equal to the server IP means the
        // traffic really flows through the VPS; anything else is a bypass.
        var egressOK = false
        if let observed = serverReport.ip {
            switch TunnelSelfTest.evaluate(expected: expected, observed: observed) {
            case .viaServer:
                slog(.success, "SELFTEST", "egress \(observed) == server -> PASS (traffic via your server)")
                egressOK = true
            case .bypass(let o):
                slog(.error, "SELFTEST", "egress \(o) != server \(expected ?? "?") -> FAIL (traffic bypasses tunnel)")
            case .unparseable(let r):
                slog(.error, "SELFTEST", "server egress report unusable (\(r)) -> FAIL")
            case .unknownExpected:
                slog(.warning, "SELFTEST", "server IP unknown (hostname \(expectedHost) unresolved) — cannot verify egress")
            }
        } else {
            slog(.warning, "SELFTEST", "egress unverified — the server could not report its egress IP (no iproute2 on server or no route). Traffic may still be fine; banner check above is the routing proof.")
        }

        // 2. Server egress path, also read by the server itself from its own
        // routing table (no traffic sent anywhere for this). "route" means a
        // default egress route exists on the server.
        if let web = serverReport.web {
            slog(web == "route" ? .success : .warning, "SELFTEST", "server egress route check -> \(web) (expected route: server has a default egress path)")
        }

        slog(.system, "SELFTEST", "traffic checks finished")
        return egressOK
    }

    /// Reads the SSH banner from the user's OWN server over plain TCP through
    /// the system stack (i.e. through the tunnel while VPN is up). Returns
    /// the banner text (e.g. "SSH-2.0-OpenSSH_9.6") or nil on any failure.
    /// The ONLY network peer here is the user's server — no third party.
    private static func readBanner(host: String, port: Int, timeout: TimeInterval,
                                   onState: ((String) -> Void)? = nil) async -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, port > 0 && port <= 65535,
              let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return nil }
        return await withCheckedContinuation { continuation in
            let box = BannerOnceBox(continuation)
            // onState is non-Sendable; the NWConnection handler is @Sendable,
            // so it crosses isolation boxed (fire-and-forget logging only).
            final class StateSink: @unchecked Sendable {
                let fn: ((String) -> Void)?
                init(_ fn: ((String) -> Void)?) { self.fn = fn }
            }
            let sink = StateSink(onState)
            let conn = NWConnection(host: NWEndpoint.Host(trimmed), port: endpointPort, using: .tcp)
            box.connection = conn
            conn.stateUpdateHandler = { state in
                switch state {
                case .setup: sink.fn?("setup")
                case .waiting(let e): sink.fn?("waiting(\(e))")
                case .preparing: sink.fn?("preparing")
                case .ready:
                    sink.fn?("ready")
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 255) { data, _, _, error in
                        if let data, SSHExecCheck.looksLikeSSHBanner(data) {
                            box.finish(String(data: data, encoding: .utf8)?
                                .trimmingCharacters(in: .whitespacesAndNewlines))
                        } else {
                            box.finish(nil)
                        }
                        _ = error
                    }
                case .failed: box.finish(nil)
                case .cancelled: box.finish(nil)
                @unknown default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                box.finish(nil)
            }
        }
    }

    /// One-shot guard: NWConnection state/receive/timeout callbacks can all
    /// fire for one banner read — resuming a continuation twice CRASHES the
    /// app. Same pattern as PingContext.
    private final class BannerOnceBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String?, Never>?
        var connection: NWConnection?

        init(_ c: CheckedContinuation<String?, Never>) { continuation = c }

        func finish(_ value: String?) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            connection?.cancel()
            c?.resume(returning: value)
        }
    }

    /// One-shot snapshot of what the SYSTEM thinks about networking: does it
    /// see our utun at all? Decisive for the delta=0 mystery (app traffic
    /// never reaching the tunnel while the extension sits alive).
    private static func logSystemPath() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let ifs = path.availableInterfaces.map { "\($0.name):\($0.type)" }.joined(separator: ",")
            let gws = path.gateways.map { "\($0)" }.joined(separator: ",")
            slog(.info, "SELFTEST", "NWPath status=\(path.status) ifs=[\(ifs)] expensive=\(path.isExpensive) v4=\(path.supportsIPv4) v6=\(path.supportsIPv6) gateways=[\(gws)]")
            monitor.cancel()
        }
        monitor.start(queue: DispatchQueue.global())
    }

    private static func slog(_ level: ConsoleLogLevel, _ tag: String, _ message: String) {
        ConsoleLogStore.shared.log(level: level, tag: tag, message: message)
    }
}

enum ConnectionPresentation: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}
