import SwiftUI
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
    @Published var serverCountry: String = ""
    @Published var serverFlag: String = "🌐"
    @Published var serverCity: String = ""
    @Published var serverPingMs: Int? = nil
    @Published var serverLatitude: Double = 50.1109
    @Published var serverLongitude: Double = 8.6821
    @Published var isResolvingMetadata: Bool = false

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
    func selectServer(id: String) {
        localStore.select(id: id)
        selectedServer = servers.first { $0.id == id }
        refreshServerMetadata()
        Task { @MainActor in
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                vpn.ensureManagerLoaded { continuation.resume() }
            }
            await VPNExtensionAPI.selectServer(id: id, from: vpn.diagnosticManager())
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
                self?.stopPhasePolling()
                ConsoleLogStore.shared.log(level: .success, tag: "TUNNEL", message: ">> ENCRYPTED TUNNEL ESTABLISHED << IP route 0.0.0.0/0 active")
                self?.logExtensionInventory()
                self?.schedulePostConnectCheck()
                self?.runPostConnectSelfTest()
            case .disconnecting:
                ConsoleLogStore.shared.log(level: .info, tag: "TUNNEL", message: "PacketTunnel state -> DISCONNECTING...")
            case .disconnected:
                self?.connection = .disconnected
                self?.stopPhasePolling()
                ConsoleLogStore.shared.log(level: .info, tag: "TUNNEL", message: "PacketTunnel state -> DISCONNECTED")
                self?.fetchTunnelDiagnostics()
            case .invalid:
                self?.connection = .disconnected
                self?.stopPhasePolling()
                ConsoleLogStore.shared.log(level: .error, tag: "TUNNEL", message: "PacketTunnel state -> INVALID CONFIGURATION")
                self?.fetchTunnelDiagnostics()
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
    }

    /// Confirms the extension-owned copy after a successful connect (the tunnel
    /// is running here, so the message channel is alive).
    private func logExtensionInventory() {
        Task { @MainActor in
            let d = await VPNExtensionAPI.call(from: vpn.diagnosticManager(), cmd: .serverList)
            let (servers, selectedID) = ServerListCoder.decodeServerList(data: d)
            ConsoleLogStore.shared.log(level: .info, tag: "TUNNEL", message: "Extension store holds \(servers.count) server(s), selected=\(selectedID ?? "none")")
            // Pull the extension's own detail lines (SSH stages) now that the
            // channel is warm, then report live counters.
            await VPNExtensionAPI.fetchLogs(from: vpn.diagnosticManager())
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
            let s = status["sessions"] ?? "?"
            let phase = status["phase"] ?? "?"
            ConsoleLogStore.shared.log(level: .info, tag: "TUNNEL", message: "Tunnel counters [\(tag)]: utun read=\(r) written=\(w) sessions=\(s) phase=\(phase)")
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
        Task.detached {
            let resolved = (try? SSHEndpointResolver.resolve(host))?.ipv4 ?? []
            await TunnelSelfTester.run(expectedHost: host, resolvedIPv4: resolved)
        }
    }

    /// Re-checks counters a while after connect while still connected, so the
    /// dump shows whether traffic actually flows (call sites: .connected).
    private func schedulePostConnectCheck() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(12))
            guard connection == .connected else { return }
            await VPNExtensionAPI.fetchLogs(from: vpn.diagnosticManager(), timeout: 2)
            logTunnelCounters(tag: "+12s")
        }
    }

    /// Pulls the last tunnel error + status from the extension and logs them.
    /// Called on disconnect/invalid so the app dump reveals WHY the tunnel died
    /// (auth failure, config error, etc.) without needing a shared container.
    private func fetchTunnelDiagnostics() {
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
            await VPNExtensionAPI.fetchLogs(from: vpn.diagnosticManager())
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
            let ping = await ServerMetadataResolver.measurePing(host: currentHost, port: currentPort)
            let geo = await ServerMetadataResolver.resolveGeo(host: currentHost)

            await MainActor.run {
                guard self.profile.host == currentHost else { return }
                self.serverPingMs = ping
                if let ping = ping {
                    ConsoleLogStore.shared.log(level: .success, tag: "PING", message: "TCP RTT latency: \(ping) ms to \(currentHost):\(currentPort)")
                } else {
                    ConsoleLogStore.shared.log(level: .warning, tag: "PING", message: "TCP ping probe timed out for \(currentHost):\(currentPort)")
                }

                if let geo = geo {
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

    func connect() {
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
        ConsoleLogStore.shared.log(level: .system, tag: "CONNECT", message: "Starting VPN connection to \(selected.host):\(selected.port) user=\(selected.username)...")
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
        beginConnection()
    }

    /// Starts the actual tunnel after the selected server is guaranteed to be
    /// persisted locally (extension sync is best-effort in the background).
    private func beginConnection() {
        _ = automation.beginConnect()
        connection = .connecting
        startPhasePolling()
        performConnectionAttempt()
        refreshServerMetadata()
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
                let status = await VPNExtensionAPI.call(from: self.vpn.diagnosticManager(), cmd: .status, timeout: 2)
                if Task.isCancelled { break }
                if let phase = status["phase"], phase != self.lastPolledPhase {
                    let from = self.lastPolledPhase ?? "?"
                    self.lastPolledPhase = phase
                    ConsoleLogStore.shared.log(level: .info, tag: "TUNNEL", message: "Tunnel phase: \(from) -> \(phase)")
                }
                let errRsp = await VPNExtensionAPI.call(from: self.vpn.diagnosticManager(), cmd: .lastError, timeout: 2)
                if Task.isCancelled { break }
                if let err = errRsp["error"], err != "none", !self.reportedLiveErrors.contains(err) {
                    self.reportedLiveErrors.insert(err)
                    ConsoleLogStore.shared.log(level: .error, tag: "TUNNEL", message: "Tunnel error (live): \(err)")
                }
                // Pull the extension's own detail lines (SSH stages live there).
                await VPNExtensionAPI.fetchLogs(from: self.vpn.diagnosticManager(), timeout: 2)
                if Task.isCancelled { break }
                try? await Task.sleep(for: .milliseconds(500))
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
        effectiveProfile.dnsServers = settings.resolvedDNSServers

        vpn.start(profile: effectiveProfile) { [weak self] error in
            guard let self = self else { return }
            if let error {
                let message = error.localizedDescription
                switch self.automation.reportFailure(error) {
                case .transientFailure(let attempt, _):
                    ConsoleLogStore.shared.log(level: .warning, tag: "RETRY", message: "Transient failure (attempt \(attempt))/\(self.automation.maxRetries): \(message). Retrying in 2s...")
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        self.connection = .connecting
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
        case .connected, .connecting:
            break
        default:
            return
        }
        ConsoleLogStore.shared.log(level: .system, tag: "DISCONN", message: "User requested VPN disconnect. Closing SSH2 tunnel...")
        _ = automation.markDisconnected()
        connection = .disconnected
        stopPhasePolling()
        vpn.stop()
    }

    func tickConnectionTimer() {
        objectWillChange.send()
        automation.tick()
    }

    var connectionActiveSeconds: Int { automation.activeSeconds }
}

struct VPNProfile: Equatable {
    var host: String
    var port: Int
    var username: String
    var password: String
    var privateKey: String
    var hostKey: String
    var dnsServers: [String] = []
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

    /// Loads (or creates) the single app manager WITHOUT starting the tunnel.
    /// Lets the app talk to the extension over the message channel before a
    /// connection exists.
    func ensureManagerLoaded(completion: @escaping () -> Void) {
        if manager != nil { completion(); return }
        resolveManager { _ in completion() }
    }

    func start(profile: VPNProfile, completion: @escaping (Error?) -> Void) {
        // Resolve (deduplicate) the single app profile before building.
        resolveManager { error in
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
            // includeAllNetworks is intentionally NOT set: the PacketTunnelProvider
            // installs its own default routes / exclusion rules. Capturing all
            // networks here would conflict and cause NEVPNErrorDomain Code=1.

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

            configurationProtocol.providerConfiguration = providerConfig
            manager.protocolConfiguration = configurationProtocol
            manager.localizedDescription = "SSH2VPN"
            manager.isEnabled = true

            manager.saveToPreferences { saveError in
                guard saveError == nil else { completion(saveError); return }
                // CRITICAL FIX (matches VPNConnectionCoordinator): reload
                // preferences after save and before start. Without this the
                // manager's in-memory state can be out of sync with the network
                // extension, producing NEVPNErrorDomain Code=1.
                manager.loadFromPreferences { reloadError in
                    guard reloadError == nil else { completion(reloadError); return }
                    do {
                        try manager.connection.startVPNTunnel()
                        completion(nil)
                    } catch {
                        completion(error)
                    }
                }
            }
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

    func stop() { manager?.connection.stopVPNTunnel() }

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

    static func run(expectedHost: String, resolvedIPv4: [String]) async {
        slog(.system, "SELFTEST", "starting post-connect traffic checks")
        let expected = TunnelSelfTest.pickExpected(host: expectedHost, resolvedIPv4: resolvedIPv4)

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
                lastErr = error.localizedDescription
                slog(.warning, "SELFTEST", "egress service \(raw) failed: \(lastErr)")
            }
        }
        if let observed {
            switch TunnelSelfTest.evaluate(expected: expected, observed: observed) {
            case .viaServer:
                slog(.success, "SELFTEST", "egress \(observed) == server -> PASS (traffic via server)")
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
                slog(.error, "SELFTEST", "https check failed: \(error.localizedDescription)")
            }
        }
        slog(.system, "SELFTEST", "traffic checks finished")
    }

    private static func slog(_ level: ConsoleLogLevel, _ tag: String, _ message: String) {
        ConsoleLogStore.shared.log(level: level, tag: tag, message: message)
    }

    private static func fetchText(url: URL, timeout: TimeInterval) async throws -> String {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "GET"
        let (data, _) = try await URLSession.shared.data(for: req)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func fetchStatus(url: URL, timeout: TimeInterval) async throws -> Int {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "GET"
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return http.statusCode
    }
}

enum ConnectionPresentation: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}
