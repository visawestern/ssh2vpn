import SwiftUI
import NetworkExtension
import VPNCore

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
    @Published var profile = VPNProfileStore.load() {
        didSet {
            VPNProfileStore.save(profile)
            refreshServerMetadata()
        }
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

    init() {
        statusObserver = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] note in
            guard let connection = note.object as? NEVPNConnection else { return }
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
                ConsoleLogStore.shared.log(level: .success, tag: "TUNNEL", message: ">> ENCRYPTED TUNNEL ESTABLISHED << IP route 0.0.0.0/0 active")
            case .disconnecting:
                ConsoleLogStore.shared.log(level: .info, tag: "TUNNEL", message: "PacketTunnel state -> DISCONNECTING...")
            case .disconnected:
                self?.connection = .disconnected
                ConsoleLogStore.shared.log(level: .info, tag: "TUNNEL", message: "PacketTunnel state -> DISCONNECTED")
            case .invalid:
                self?.connection = .disconnected
                ConsoleLogStore.shared.log(level: .error, tag: "TUNNEL", message: "PacketTunnel state -> INVALID CONFIGURATION")
            @unknown default:
                self?.connection = .failed("Unknown VPN state")
                ConsoleLogStore.shared.log(level: .error, tag: "TUNNEL", message: "PacketTunnel state -> UNKNOWN")
            }
        }
        ConsoleLogStore.shared.log(level: .system, tag: "BOOT", message: "SSH2VPN v1.0.0 Cyber Terminal Logger Initialized")
        refreshServerMetadata()
    }

    /// Keep the screen awake while the main window is active and during an
    /// established VPN connection, so the device never sleeps mid-session.
    private func updateIdleTimer() {
        let keepAwake: Bool
        switch connection {
        case .connected, .connecting: keepAwake = true
        case .disconnected, .failed: keepAwake = false
        }
        Task { @MainActor in
            UIApplication.shared.isIdleTimerDisabled = keepAwake
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
        ConsoleLogStore.shared.log(level: .system, tag: "CONNECT", message: "Starting VPN connection to \(profile.host):\(profile.port) user=\(profile.username)...")
        if !profile.privateKey.isEmpty {
            ConsoleLogStore.shared.log(level: .ssh, tag: "AUTH", message: "Using Ed25519 private key authentication")
        } else if !profile.password.isEmpty {
            ConsoleLogStore.shared.log(level: .ssh, tag: "AUTH", message: "Using password authentication from secure Keychain")
        }
        if !profile.hostKey.isEmpty {
            ConsoleLogStore.shared.log(level: .ssh, tag: "HOSTKEY", message: "Verifying pinned host key: \(profile.hostKey)")
        }

        _ = automation.beginConnect()
        connection = .connecting
        performConnectionAttempt()
        refreshServerMetadata()
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
        ConsoleLogStore.shared.log(level: .system, tag: "DISCONN", message: "User requested VPN disconnect. Closing SSH2 tunnel...")
        _ = automation.markDisconnected()
        connection = .disconnected
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

private enum VPNProfileStore {
    nonisolated(unsafe) private static let defaults = UserDefaults(suiteName: "group.com.sshtunnel.shared") ?? .standard
    private static let key = "vpn.profile.metadata"

    static func load() -> VPNProfile {
        guard let data = defaults.data(forKey: key), let stored = try? JSONDecoder().decode(StoredProfile.self, from: data) else {
            return VPNProfile(host: "", port: 22, username: "", password: "", privateKey: "", hostKey: "")
        }
        // Recover the password from Keychain (round-trips cleanly). The private
        // key is left empty here because it is stored as a base64 32-byte seed
        // (not a text key), so it cannot round-trip through VPNProfile.privateKey;
        // it is restored inside VPNController.start() instead.
        let password = (try? KeychainStore.read(account: "vps:\(stored.host):\(stored.username)")) ?? ""
        return VPNProfile(host: stored.host, port: stored.port, username: stored.username,
                          password: password, privateKey: "", hostKey: stored.hostKey)
    }

    static func save(_ profile: VPNProfile) {
        let stored = StoredProfile(host: profile.host, port: profile.port, username: profile.username, hostKey: profile.hostKey)
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: key) }
        // Persist the password to Keychain immediately (not lazily at first
        // connect), so an app restart before any tunnel attempt does not lose it.
        if !profile.password.isEmpty {
            try? KeychainStore.save(password: profile.password, account: "vps:\(profile.host):\(profile.username)")
        }
    }

    private struct StoredProfile: Codable {
        let host: String
        let port: Int
        let username: String
        let hostKey: String
    }
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

private final class VPNController {
    private let manager = NETunnelProviderManager()
    private let providerBundleIdentifier = "com.sshtunnel.app.packet-tunnel"

    func start(profile: VPNProfile, completion: @escaping (Error?) -> Void) {
        manager.loadFromPreferences { [manager] error in
            guard error == nil else { completion(error); return }

            // Restore any secrets the in-memory profile may be missing (e.g.
            // after a cold app start, when UI load() cannot round-trip the
            // base64 key). Without this, the builder would throw
            // missingCredentials even though the user already stored credentials.
            let passwordKey = "vps:\(profile.host):\(profile.username)"
            let privateKeyKey = "vps-key:\(profile.host):\(profile.username)"
            let password = profile.password.isEmpty
                ? ((try? KeychainStore.read(account: passwordKey)) ?? "")
                : profile.password
            // Keychain holds the key as base64(32-byte seed). Recover it as a
            // 64-char hex string so canonicalSeed() round-trips it idempotently
            // and the builder sees a non-empty credential.
            var privateKey = profile.privateKey
            if privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let encoded = try? KeychainStore.read(account: privateKeyKey),
               let seed = Data(base64Encoded: encoded) {
                privateKey = seed.map { String(format: "%02x", $0) }.joined()
            }

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

            if !profile.password.isEmpty && password != profile.password {
                try? KeychainStore.save(password: profile.password, account: passwordKey)
            }

            // Start from the builder's provider config (host/port/user/hostKey/dns)
            // and layer in the App-target Keychain credential keys, which the
            // builder cannot know about.
            var providerConfig = configuration.providerConfiguration
            if password.isEmpty == false || KeychainStore.contains(account: passwordKey) {
                providerConfig["passwordKey"] = passwordKey
            }
            if !profile.privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                do {
                    let seed = try SSHPrivateKeyImporter.canonicalSeed(from: Data(profile.privateKey.utf8))
                    try KeychainStore.save(password: seed.base64EncodedString(), account: privateKeyKey)
                    providerConfig["privateKeyKey"] = privateKeyKey
                } catch { completion(error); return }
            }
            if KeychainStore.contains(account: privateKeyKey) {
                providerConfig["privateKeyKey"] = privateKeyKey
            }

            VPNProfileStore.save(profile)
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

    func stop() { manager.connection.stopVPNTunnel() }
}

enum ConnectionPresentation: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}
