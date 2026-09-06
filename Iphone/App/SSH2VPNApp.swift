import SwiftUI
import Network
import NetworkExtension
import VPNCore
import os

@main
struct SSH2VPNApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedLanguage: AppLanguage? = LanguageStore.current
    @Published var connection = ConnectionPresentation.disconnected {
        didSet { updateIdleTimer() }
    }
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

    // MARK: - Free-time quota (3h free, then +3h per rewarded-ad view)
    @Published var quota: AdQuota = AdQuotaStore().load()
    /// True while the ad stub is "playing" (disables the button).
    @Published var adPlaying = false

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
    @Published var serverFlag: String = "🌐"
    @Published var serverCity: String = ""
    @Published var serverPingMs: Int? = nil
    @Published var serverLatitude: Double = 50.1109
    @Published var serverLongitude: Double = 8.6821
    @Published var isResolvingMetadata: Bool = false
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
    private var killSwitchAttempts = 0

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
        refreshServerMetadata()
        refreshAllServerMetadata()
    }

    /// Adds or updates a server locally (instant UI), then best-effort syncs
    /// it to the extension (applies when the tunnel/manager is reachable).
    func saveServer(_ profile: ServerProfile) {
        var p = profile
        p.hasPassword = p.password?.isEmpty == false
        p.hasPrivateKey = p.privateKey?.isEmpty == false
        localStore.save(p)
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

    /// Reconciles the model's connection state with what NetworkExtension
    /// actually reports. Heals the drift where the UI keeps showing
    /// connected/connecting after the tunnel died without a status event —
    /// that drift froze server switching even though "nothing was running".
    func resyncConnectionStateWithSystem() {
        guard let status = vpn.currentSystemStatus() else { return }
        let presentation: ConnectionPresentation
        switch status {
        case .connected: presentation = .connected
        case .connecting, .reasserting: presentation = .connecting
        case .disconnecting: presentation = .connecting // still winding down
        case .disconnected, .invalid: presentation = .disconnected
        @unknown default: return
        }
        if presentation == .disconnected && (connection == .connected || connection == .connecting) {
            ConsoleLogStore.shared.log(level: .warning, tag: "SERVER",
                message: "state drift healed: model said \(connection) but the tunnel is actually down")
            connection = .disconnected
            stopPhasePolling()
            stopStatsPolling()
            attemptStartedAt = nil
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
        serverCity = ""
        serverLatitude = 50.1109
        serverLongitude = 8.6821
        serverPingMs = nil
    }

    init() {
        statusObserver = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] note in
            guard let connection = note.object as? NEVPNConnection else { return }
            // Ignore chatter from stale/foreign VPN profiles: only our
            // manager's connection may drive UI state and diagnostics.
            if let self, !self.vpn.owns(connection) { return }
            // Pre-invoke stale filter: nothing of ours is running yet, so a
            // disconnect here is definitionally stale (prefs churn re-posting
            // DISCONNECTED) — accepting it would clobber a fresh .connecting
            // and orphan the whole attempt. Real failures always arrive AFTER
            // startVPNTunnel was invoked, when the flag is set.
            if connection.status == .disconnected || connection.status == .disconnecting {
                if let self, !self.vpn.didInvokeStart { return }
            }
            // Collapse identical bursts (system double-posts) in the log.
            // State below still updates, so a repeated status is harmless.
            let now = Date()
            if let self, !TunnelLogDedupe.shouldLog(current: connection.status, last: self.lastRawStatus, lastAt: self.lastRawAt, now: now) {
                return
            }
            self?.lastRawStatus = connection.status
            self?.lastRawAt = now
            switch connection.status {
            case .connecting:
                self?.connection = .connecting
                ConsoleLogStore.shared.log(level: .ssh, tag: "TUNNEL", message: "PacketTunnel state -> CONNECTING...")
            case .reasserting:
                self?.connection = .connecting
                ConsoleLogStore.shared.log(level: .warning, tag: "TUNNEL", message: "PacketTunnel state -> REASSERTING")
            case .connected:
                _ = self?.automation.markConnected()
                self?.connection = .connected
                self?.userIntentConnected = true
                self?.killSwitchAttempts = 0
                self?.startStatsPolling()
                self?.attemptStartedAt = nil
                self?.stallRestartArmed = false
                self?.lastStallRead = nil
                self?.stallFrozenCycles = 0
                self?.stopPhasePolling()
                ConsoleLogStore.shared.log(level: .success, tag: "TUNNEL", message: ">> ENCRYPTED TUNNEL ESTABLISHED << IP route 0.0.0.0/0 active")
                self?.logExtensionInventory()
                self?.schedulePostConnectCheck()
            case .disconnecting:
                ConsoleLogStore.shared.log(level: .info, tag: "TUNNEL", message: "PacketTunnel state -> DISCONNECTING...")
            case .disconnected:
                if let self, self.stallRestartArmed {
                    // Expected goodbye from the old tunnel during a stall
                    // restart; the fresh attempt is already in flight. Consume
                    // the flag and leave .connecting alone.
                    self.stallRestartArmed = false
                    ConsoleLogStore.shared.log(level: .info, tag: "TUNNEL", message: "PacketTunnel state -> DISCONNECTED (stale drop from stall restart, new attempt in flight)")
                } else if let self, self.connection == .connecting, self.isEarlyDeath() {
                    ConsoleLogStore.shared.log(level: .info, tag: "TUNNEL", message: "PacketTunnel state -> DISCONNECTED (early, attempt in flight — diagnosing)")
                    self.diagnoseEarlyDeathAndMaybeRetry()
                } else {
                    self?.connection = .disconnected
                    self?.stopPhasePolling()
                    self?.stopStatsPolling()
                    self?.attemptStartedAt = nil
                    ConsoleLogStore.shared.log(level: .info, tag: "TUNNEL", message: "PacketTunnel state -> DISCONNECTED")
                    self?.fetchTunnelDiagnostics()
                    self?.scheduleZombieTunnelCheck()
                    // Kill switch (Advanced settings): the tunnel died on its
                    // own while the user wanted it ON — redial automatically
                    // with exponential backoff instead of silently dropping
                    // the phone onto the raw network.
                    if let self {
                        if self.userIntentConnected, self.settings.killSwitch {
                            self.scheduleKillSwitchReconnect()
                        } else {
                            self.userIntentConnected = false
                        }
                    }
                }
            case .invalid:
                self?.connection = .disconnected
                self?.stopPhasePolling()
                self?.attemptStartedAt = nil
                ConsoleLogStore.shared.log(level: .error, tag: "TUNNEL", message: "PacketTunnel state -> INVALID CONFIGURATION — removing broken profile, tap connect to recreate")
                self?.repairInvalidProfile()
            @unknown default:
                self?.connection = .failed("Unknown VPN state")
                self?.stopPhasePolling()
                ConsoleLogStore.shared.log(level: .error, tag: "TUNNEL", message: "PacketTunnel state -> UNKNOWN")
            }
        }
        ConsoleLogStore.shared.log(level: .system, tag: "BOOT", message: "SSH2VPN v1.0.0 Cyber Terminal Logger Initialized")
        // Re-apply the idle-lock whenever the app enters the foreground so the
        // screen stays on for the whole time the user is inside the app.
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateIdleTimer()
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateIdleTimer()
        }
        refreshServerMetadata()
        // Load the local server list on launch (instant, no extension needed).
        loadServerList()
        startServerPingTimer()
        // Warm the NE manager in the background so status re-syncs (server
        // switching, connect gating) always have the real system state.
        vpn.ensureManagerLoaded { }
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

    /// Kicks off the post-connect traffic self-test (egress IP vs server IP +
    /// HTTPS reachability). Runs detached so blocking DNS never touches the
    /// main thread; results land in the console log.
    private func runPostConnectSelfTest() {
        guard let selected = selectedServer else {
            ConsoleLogStore.shared.log(level: .warning, tag: "SELFTEST", message: "skipped: no selected server")
            return
        }
        let host = selected.host
        Task { @MainActor in
            let before = await self.utunReadCount()
            // Blocking DNS resolve stays off the main thread; awaits below
            // never block (URLSession/NWConnection suspend, not spin).
            let resolved = await Task.detached { (try? SSHEndpointResolver.resolve(host))?.ipv4 ?? [] }.value
            let egressOK = await TunnelSelfTester.run(
                expectedHost: host,
                resolvedIPv4: resolved,
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
    /// Exponential backoff 1s..60s; resets on success or a manual connect.
    private func scheduleKillSwitchReconnect() {
        killSwitchAttempts += 1
        let delay = min(60.0, pow(2.0, Double(min(killSwitchAttempts, 6))))
        ConsoleLogStore.shared.log(level: .warning, tag: "KILLSWITCH",
            message: "tunnel dropped while kill switch is ON — auto-reconnecting in \(Int(delay))s (attempt \(killSwitchAttempts))")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            // The user may have disconnected (or reconnected manually) during
            // the backoff — the redial is only for a still-wanted tunnel.
            guard self.userIntentConnected, self.settings.killSwitch,
                  self.connection == .disconnected else { return }
            guard self.remainingQuotaSeconds > 0 else {
                ConsoleLogStore.shared.log(level: .warning, tag: "KILLSWITCH", message: "auto-reconnect skipped: free time exhausted")
                self.userIntentConnected = false
                return
            }
            guard let selected = self.selectedServer else { return }
            ConsoleLogStore.shared.log(level: .info, tag: "KILLSWITCH", message: "auto-reconnecting to \(selected.host)...")
            self.connect()
        }
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
                guard let self else { return }
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

    func choose(_ language: AppLanguage) {
        selectedLanguage = language
        LanguageStore.current = language
        ConsoleLogStore.shared.log(level: .system, tag: "LANG", message: "Interface language updated -> \(language.title)")
    }

    /// GeoIP only (no TCP ping): every port-22 SYN counts against the VPS
    /// per-source rate limiter (~6/30s), so SYNs are spent ONLY on real SSH
    /// connects plus the slow ping loop. Ping freshness comes from the
    /// load-time sweep, the minutely selected-only tick and the list view.
    func refreshServerMetadata() {
        guard !profile.host.isEmpty else {
            serverCountry = ""
            serverFlag = "🌐"
            serverCity = ""
            serverPingMs = nil
            return
        }

        isResolvingMetadata = true
        let currentHost = profile.host
        let currentPort = profile.port

        ConsoleLogStore.shared.log(level: .info, tag: "PROBE", message: "Analyzing remote server \(currentHost):\(currentPort)...")

        Task {
            // GeoIP only for a host we haven't located yet (failures are not
            // cached, so an offline lookup simply retries next time).
            let geo: ServerGeoInfo? = (lastGeoHost == currentHost) ? nil : await ServerMetadataResolver.resolveGeo(host: currentHost)

            await MainActor.run {
                guard self.profile.host == currentHost else { return }

                if let geo = geo {
                    self.lastGeoHost = currentHost
                    self.serverCountry = geo.country
                    self.serverFlag = geo.flag
                    self.serverCity = geo.city
                    self.serverLatitude = geo.lat
                    self.serverLongitude = geo.lon
                    if self.serverName.isEmpty || self.serverName == "My VPS" || self.serverName == currentHost {
                        self.serverName = "\(geo.flag) \(geo.country)"
                    }
                    ConsoleLogStore.shared.log(level: .success, tag: "GEOIP", message: "GeoIP located: \(geo.flag) \(geo.country) (\(geo.city)) [\(geo.lat), \(geo.lon)]")
                }
                self.isResolvingMetadata = false
            }
        }
    }

    /// Fetch GeoIP + ping for all servers in the list (runs in background,
    /// populates per-server caches). Called on every server-list load.
    func refreshAllServerMetadata() {
        let targets = servers
        guard !targets.isEmpty else { return }
        Task {
            var geoResults: [String: ServerGeoInfo] = [:]
            var pingResults: [String: Int] = [:]
            await withTaskGroup(of: (String, ServerGeoInfo?, Int?).self) { group in
                for server in targets {
                    group.addTask {
                        // Ping FIRST (user-visible badge); GeoIP lags behind.
                        // Previously geo (up to 6s) blocked the ping.
                        let ping = await ServerMetadataResolver.measurePing(host: server.host, port: server.port)
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

    /// Minutely ping-only refresh for every server (cheap; GeoIP is cached
    /// from load and never re-fetched here — public GeoIP APIs rate-limit).
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

    func connect() {
        // Kill-switch bookkeeping: a manual connect is user intent; the
        // redial after an unexpected drop only fires while this stays true.
        userIntentConnected = true
        killSwitchAttempts = 0
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
        // Free-tier gate: no quota, no tunnel. The user earns more by
        // watching a rewarded ad (stub) from the main screen.
        guard remainingQuotaSeconds > 0 else {
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
        saveServer(selected)
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
                if let resolved = try? await SSHEndpointResolver.resolve(selected.host),
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
            switch self.automation.reportFailure(msg) {
            case .transientFailure(let attempt, _):
                ConsoleLogStore.shared.log(level: .warning, tag: "RETRY", message: "Early death (attempt \(attempt))/\(self.automation.maxRetries): \(msg). Retrying in 2s via saved config...")
                try? await Task.sleep(for: .seconds(2))
                guard self.connection == .connecting else { return }
                self.attemptStartedAt = Date()
                self.performConnectionAttempt()
            case .gaveUpAfterRetries(let m):
                self.attemptStartedAt = nil
                self.stopPhasePolling()
                self.connection = .failed(m)
                ConsoleLogStore.shared.log(level: .error, tag: "FAIL", message: "Gave up after \(self.automation.maxRetries) attempts: \(m)")
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
        // Local rules travel with the profile to the extension (JSON).
        effectiveProfile.dnsRules = DNSBlocklistEntry.encodeList(settings.dnsRules) ?? "[]"
        // Capture pre-resolved IP for this attempt (avoids blocking DNS in extension).
        let serverIP = cachedServerIPv4

        // No app-side TCP ping gate: the SSH connect itself IS the probe
        // (extension has a 10s connect timeout), and every extra port-22 SYN
        // feeds the VPS per-source rate limiter. One tap = one SSH SYN.
        self.vpn.start(profile: effectiveProfile, serverIP: serverIP,
                       onDemandEnabled: settings.connectOnDemand) { [weak self] error in
            guard let self = self else { return }
            if let error {
                let message = error.localizedDescription
                switch self.automation.reportFailure(error) {
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
                        self.performConnectionAttempt()
                    }
                case .gaveUpAfterRetries(let msg):
                    self.connection = .failed(msg)
                    ConsoleLogStore.shared.log(level: .error, tag: "FAIL", message: "Gave up after \(self.automation.maxRetries) attempts: \(msg)")
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
        killSwitchAttempts = 0
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
        // Free-time drain: one quota second per connected second. When the
        // well runs dry the session ends itself — the UI already shows the
        // countdown and the ad button.
        guard connection == .connected else { return }
        quota.consume(1)
        AdQuotaStore().save(quota)
        if remainingQuotaSeconds <= 0 {
            ConsoleLogStore.shared.log(level: .warning, tag: "QUOTA",
                                       message: "Free time exhausted — disconnecting until an ad is watched")
            disconnect()
            connection = .failed("freeTimeExhausted")
        }
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
        let newRule = DNSBlocklistEntry(domain: normalized, kind: kind, ip: kind == .override ? ip : "")
        if let replacing, let idx = settings.dnsRules.firstIndex(where: { $0.id == replacing.id }) {
            settings.dnsRules[idx] = newRule
            ConsoleLogStore.shared.log(level: .info, tag: "DNSFILTER",
                message: "local rule updated: \(normalized) -> \(kind == .block ? "0.0.0.0" : ip)")
        } else {
            settings.dnsRules.append(newRule)
            ConsoleLogStore.shared.log(level: .info, tag: "DNSFILTER",
                message: "local rule added: \(normalized) -> \(kind == .block ? "0.0.0.0" : ip)")
        }
        return nil
    }

    func removeDNSRule(id: UUID) {
        settings.dnsRules.removeAll { $0.id == id }
    }

    // MARK: - Live tunnel stats + ad quota

    /// Remaining quota accounting for the LIVE session too (the struct only
    /// gets drained via ticks — subtracting activeSeconds keeps the countdown
    /// real between ticks).
    var remainingQuotaSeconds: TimeInterval {
        max(0, quota.remainingSeconds - TimeInterval(automation.activeSeconds))
    }

    /// Seconds until the ad button unlocks (0 = ready to watch now).
    var adCooldownRemaining: TimeInterval { quota.adCooldownRemaining(now: Date()) }

    var canWatchAd: Bool { quota.canWatchAd(now: Date()) && !adPlaying }

    /// Rewarded-ad stub: simulates a 2s ad view, then banks +3h. Real SDK
    /// slots in here later — only this function changes.
    func watchAd() {
        guard canWatchAd else { return }
        adPlaying = true
        ConsoleLogStore.shared.log(level: .info, tag: "ADS", message: "rewarded ad requested (STUB — 2s simulated view)")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            self.adPlaying = false
            if self.quota.watchAd(now: Date()) {
                AdQuotaStore().save(self.quota)
                let hours = Int(self.quota.bankedSeconds / 3600)
                ConsoleLogStore.shared.log(level: .success, tag: "ADS", message: "reward credited: +3h (banked \(hours)h total)")
            } else {
                ConsoleLogStore.shared.log(level: .warning, tag: "ADS", message: "ad not credited (cooldown or bank full)")
            }
        }
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

            // Embed credentials directly in the tunnel provider configuration
            // (plain local storage, matching how the profile is persisted) so
            // the packet-tunnel extension needs no Keychain dependency and
            // cannot fail with keychainUnavailable.
            var providerConfig = configuration.providerConfiguration
            if !password.isEmpty {
                providerConfig["password"] = password
            }
            if !privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                providerConfig["privateKey"] = privateKey
            }
            // Pre-resolved server IPv4 (avoids blocking DNS in extension startTunnel,
            // which caused early-death flake where iOS killed the extension for slow launch).
            if let serverIP {
                providerConfig["serverIP"] = serverIP
            }
            // Local DNS rules (block/override): the extension answers these
            // domains locally before any upstream query (JSON-encoded list).
            if !profile.dnsRules.isEmpty, profile.dnsRules != "[]" {
                providerConfig["dnsRules"] = profile.dnsRules
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
            let pendingOnDemand = onDemandEnabled

            manager.saveToPreferences { [weak self] saveError in
                guard let self else { return }
                // Save failed (typically: system VPN-consent dialog still
                // pending on first install) — wait for creation instead of
                // failing the attempt outright. See waitForProfileCreation.
                if saveError != nil {
                    self.pendingCreationCompletion = completion
                    self.waitForProfileCreation(epoch: epoch, saveError: saveError, budget: RetryBudget())
                    return
                }
                // CRITICAL FIX (matches VPNConnectionCoordinator): reload
                // preferences after save and before start. Without this the
                // manager's in-memory state can be out of sync with the network
                // extension, producing NEVPNErrorDomain Code=1.
                self.reloadAndStart(manager: manager, completion: completion)
            }
        }
    }

    /// Reloads preferences after a save (keeps the manager in sync with the
    /// network extension — otherwise NEVPNErrorDomain Code=1) and starts.
    /// Nonisolated: touches only its arguments, so unchecked system callbacks
    /// can use it without dragging non-Sendable values across isolation.
    private nonisolated func reloadAndStart(manager: NETunnelProviderManager, completion: @escaping (Error?) -> Void) {
        manager.loadFromPreferences { [weak self] reloadError in
            guard reloadError == nil else { completion(reloadError); return }
            self?.didInvokeStart = true
            do {
                try manager.connection.startVPNTunnel()
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    /// Completion parked while waiting for profile creation. MainActor-owned
    /// so async ticks can reacquire it without moving non-Sendable values
    /// (manager/completion) across isolation domains. Cleared on every new
    /// start/stop so a superseded wait never fires a stale completion.
    private var pendingCreationCompletion: ((Error?) -> Void)?

    /// Waits for a freshly saved VPN profile to become creatable: retries the
    /// save every 5 seconds for up to 2 minutes (first install: the system
    /// consent dialog may still be pending), then surfaces the last error.
    /// Aborts silently when superseded by a newer start or by stop().
    private func waitForProfileCreation(
        epoch: Int,
        saveError: Error?,
        budget: RetryBudget
    ) {
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
            manager.saveToPreferences { [weak self] retryError in
                guard let self, self.startEpoch == epoch else { return }
                if retryError == nil {
                    ConsoleLogStore.shared.log(level: .success, tag: "VPN", message: "VPN profile created after waiting")
                    self.reloadAndStart(manager: manager, completion: completion)
                } else {
                    self.waitForProfileCreation(epoch: epoch, saveError: retryError, budget: budget)
                }
            }
        }
    }

    /// Starts the tunnel on an already-configured manager (reuse path — the
    /// stored configuration already matches, so no save is needed).
    /// Nonisolated: touches only its arguments (see reloadAndStart).
    private nonisolated func startTunnelNow(manager: NETunnelProviderManager, completion: @escaping (Error?) -> Void) {
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
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            guard let self else { completion(); return }
            let mine = (managers ?? []).filter {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.providerBundleIdentifier
            }
            guard !mine.isEmpty else {
                self.manager = nil
                self.knownConnection = nil
                completion()
                return
            }
            let group = DispatchGroup()
            for m in mine {
                group.enter()
                m.removeFromPreferences { _ in group.leave() }
            }
            group.notify(queue: .main) { [weak self] in
                self?.manager = nil
                self?.knownConnection = nil
                completion()
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
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            if let error {
                // A transient load error shouldn't block a first-time create.
                self.manager = NETunnelProviderManager()
                self.knownConnection = self.manager?.connection
                completion(nil)
                return
            }
            let isAppProfile: (NETunnelProviderManager) -> Bool = { m in
                (m.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.providerBundleIdentifier
            }
            let existing = managers?.first(where: isAppProfile)
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
                let stale = (managers ?? []).filter {
                    TunnelOwnership.isStaleLegacy(bundleID: ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier)
                }
                for s in stale {
                    s.removeFromPreferences { _ in }
                }
                if !stale.isEmpty {
                    let count = stale.count
                    Task { @MainActor in
                        ConsoleLogStore.shared.log(level: .warning, tag: "VPN", message: "Removed \(count) stale com.sshtunnel VPN profile(s) (one-time migration)")
                    }
                }
            }
            // Delete any leftover duplicates (beyond the first) so the system
            // settings don't accumulate identical app profiles.
            if let managers {
                let dupes = managers.filter(isAppProfile)
                for dupe in dupes.dropFirst() {
                    dupe.removeFromPreferences { _ in }
                }
            }
            completion(nil)
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

/// Post-connect traffic self-test: verifies the egress IP really belongs to
/// the server (via known echo services) plus a plain HTTPS reachability
/// check. Runs detached (blocking DNS stays off the main thread); results go
/// to the console log. Diagnostic only — never gates the UI state.
enum TunnelSelfTester {
    /// Ordered echo services returning the caller IP as plain text.
    static let echoURLs = ["https://api.ipify.org", "https://ifconfig.me/ip"]
    static let httpsCheckURL = "https://www.google.com/generate_204"

    static func run(expectedHost: String, resolvedIPv4: [String], utunReadBefore: Int? = nil) async -> Bool {
        slog(.system, "SELFTEST", "starting post-connect traffic checks")
        logSystemPath()
        // Interface table AS THE APP SEES IT: if utun is missing here while
        // the extension sees it, the app's sockets can never use the tunnel.
        slog(.info, "SELFTEST", "app-ifaces [\(LocalInterfaceNets.describeInterfaces().joined(separator: ","))]")
        if let before = utunReadBefore {
            slog(.info, "SELFTEST", "utun read before=\(before)")
        }
        let expected = TunnelSelfTest.pickExpected(host: expectedHost, resolvedIPv4: resolvedIPv4)

        // 0. System TCP sanity WITHOUT DNS: direct-IP connect through the
        // system stack. Separates "iOS routes nothing" from "DNS broken".
        // State machine fully traced: hangs in setup/waiting (no route) look
        // different from instant failed(RST) and from ready-then-stall.
        let sysPing = await ServerMetadataResolver.measurePing(host: "8.8.8.8", port: 443) { st in
            slog(.info, "SELFTEST", "probe 8.8.8.8:443 state=\(st)")
        }
        if let ms = sysPing {
            slog(.success, "SELFTEST", "system TCP 8.8.8.8:443 OK (\(ms) ms) — system routes traffic, DNS/HTTP layer suspect")
        } else {
            slog(.error, "SELFTEST", "system TCP 8.8.8.8:443 FAILED (nil) — system stack itself can't connect; VPN routes likely inactive")
        }

        // 1. Egress IP via known echo services (first success wins).
        var observed: String?
        var lastErr = "none attempted"
        for raw in echoURLs {
            guard let url = URL(string: raw) else { continue }
            do {
                let ip = try await fetchText(url: url, timeout: 8)
                observed = TunnelSelfTest.normalizeIP(ip)
                slog(.info, "SELFTEST", "egress service \(raw) -> \(observed ?? "?")")
                break
            } catch {
                lastErr = "\(error.localizedDescription) \(classify(error))"
                slog(.warning, "SELFTEST", "egress service \(raw) failed: \(lastErr)")
            }
        }
        var egressOK = false
        if let observed {
            switch TunnelSelfTest.evaluate(expected: expected, observed: observed) {
            case .viaServer:
                slog(.success, "SELFTEST", "egress \(observed) == server -> PASS (traffic via server)")
                egressOK = true
            case .bypass(let o):
                slog(.error, "SELFTEST", "egress \(o) != server \(expected ?? "?") -> FAIL (traffic bypasses tunnel)")
            case .unparseable(let r):
                slog(.error, "SELFTEST", "egress response unusable (\(r)) -> FAIL")
            case .unknownExpected:
                slog(.warning, "SELFTEST", "server IP unknown (hostname \(expectedHost) unresolved) — cannot verify egress")
            }
        } else {
            slog(.error, "SELFTEST", "all egress echo services failed (last: \(lastErr)) — DNS or egress broken")
        }

        // 2. Plain HTTPS reachability through the tunnel.
        if let url = URL(string: httpsCheckURL) {
            do {
                let code = try await fetchStatus(url: url, timeout: 8)
                slog(code == 204 ? .success : .warning, "SELFTEST", "https check \(httpsCheckURL) -> HTTP \(code) (expected 204)")
            } catch {
                slog(.error, "SELFTEST", "https check failed: \(error.localizedDescription) \(classify(error))")
            }
        }
        slog(.system, "SELFTEST", "traffic checks finished")
        return egressOK
    }

    /// Maps a fetch error to an actionable hint. Fetches run on raw
    /// NWConnection (no URLSession), so errors are URLError(.timedOut /
    /// .cancelled) or NWError — not the old -1009 family.
    private static func classify(_ error: Error) -> String {
        if let urlErr = error as? URLError {
            switch urlErr.code {
            case .timedOut:
                return "[TIMEOUT: no reply within window — SYN never answered (routing stall) or upstream silent]"
            case .cancelled:
                return "[CANCELLED]"
            case .notConnectedToInternet:
                return "[-1009 NO_PATH: system reports no route]"
            case .cannotFindHost:
                return "[-1003 DNS: hostname unresolvable]"
            default:
                return "[URLError \(urlErr.code.rawValue)]"
            }
        }
        let ns = error as NSError
        return "[\(ns.domain) \(ns.code): \(error.localizedDescription)]"
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

    private static func fetchText(url: URL, timeout: TimeInterval) async throws -> String {
        let (_, body) = try await fetchTLS(url: url, method: "GET", timeout: timeout)
        return String(data: body, encoding: .utf8) ?? ""
    }

    private static func fetchStatus(url: URL, timeout: TimeInterval) async throws -> Int {
        let (code, _) = try await fetchTLS(url: url, method: "HEAD", timeout: timeout)
        guard code != 0 else { throw URLError(.badServerResponse) }
        return code
    }

    /// One-shot guard: NWConnection state/receive/timeout callbacks can all
    /// fire for one fetch — resuming a continuation twice CRASHES the app
    /// (this killed us mid-self-test). Same pattern as PingContext.
    private final class TLSFetchOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private let continuation: CheckedContinuation<(Int, Data), Error>
        var connection: NWConnection?
        init(_ c: CheckedContinuation<(Int, Data), Error>) { continuation = c }
        func finish(_ result: Result<(Int, Data), Error>) {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return }
            done = true
            connection?.cancel()
            switch result {
            case .success(let v): continuation.resume(returning: v)
            case .failure(let e): continuation.resume(throwing: e)
            }
        }
    }

    /// Mutable fetch state boxed so @Sendable NWConnection closures can
    /// share it without capturing a local var (Swift 6 concurrency).
    private final class TLSFetchState: @unchecked Sendable {
        var received = Data()
    }

    /// Raw HTTPS fetch over an explicit TLS connection. Bypasses URLSession's
    /// NWPath reachability gate (reports "offline" for the virtual utun
    /// interface) and speaks real TLS — plaintext HTTP to :443 never worked.
    private static func fetchTLS(url: URL, method: String, timeout: TimeInterval) async throws -> (Int, Data) {
        let host = url.host ?? ""
        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        let path = url.path.isEmpty ? "/" : url.path
        let query = url.query.map { "?\($0)" } ?? ""
        return try await withCheckedThrowingContinuation { continuation in
            let once = TLSFetchOnce(continuation)
            let box = TLSFetchState()
            let params: NWParameters
            if url.scheme == "https" {
                let tls = NWProtocolTLS.Options()
                host.withCString { sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, $0) }
                params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
            } else {
                params = .tcp
            }
            let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: UInt16(port)), using: params)
            once.connection = conn
            let request = "\(method) \(path)\(query) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n"
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: request.data(using: .utf8), contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed({ _ in }))
                case .failed(let error):
                    if box.received.isEmpty { once.finish(.failure(error)) } else { Self.tlsParseAndFinish(box: box, once: once) }
                case .cancelled:
                    once.finish(.failure(URLError(.cancelled)))
                default:
                    break
                }
            }
            conn.start(queue: .global())
            Self.tlsPump(conn: conn, box: box, once: once)
            // Timeout can only win the race once (see TLSFetchOnce).
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.finish(.failure(URLError(.timedOut)))
            }
        }
    }

    /// TLS response parser (type-level: must not capture caller state — it
    /// runs inside @Sendable NWConnection callbacks).
    private static func tlsParseAndFinish(box: TLSFetchState, once: TLSFetchOnce) {
        let received = box.received
        guard let headerEnd = received.firstRange(of: Data("\r\n\r\n".utf8)) else {
            once.finish(.failure(URLError(.badServerResponse)))
            return
        }
        let head = String(data: received[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
        let code = head.split(separator: "\r\n").first
            .flatMap { $0.split(separator: " ").dropFirst().first }
            .flatMap { Int($0) } ?? 0
        once.finish(.success((code, Data(received[headerEnd.upperBound...]))))
    }

    /// Receive-until-close pump (type-level for the same Sendable reason).
    private static func tlsPump(conn: NWConnection, box: TLSFetchState, once: TLSFetchOnce) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let data { box.received.append(data) }
            if isComplete || error != nil {
                // Server closed (or failed) — parse whatever arrived.
                if box.received.isEmpty, let error {
                    once.finish(.failure(error))
                } else {
                    tlsParseAndFinish(box: box, once: once)
                }
                return
            }
            tlsPump(conn: conn, box: box, once: once)
        }
    }
}

enum ConnectionPresentation: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}
