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
    @Published var connection = ConnectionPresentation.disconnected
    @Published var serverName = "My VPS"
    @Published var profile = VPNProfileStore.load() {
        didSet {
            VPNProfileStore.save(profile)
            refreshServerMetadata()
        }
    }
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

        connection = .connecting
        vpn.start(profile: profile) { [weak self] error in
            if let error {
                self?.connection = .failed(error.localizedDescription)
                ConsoleLogStore.shared.log(level: .error, tag: "FAIL", message: "VPN connection failed: \(error.localizedDescription)")
            }
        }
        refreshServerMetadata()
    }

    func disconnect() {
        ConsoleLogStore.shared.log(level: .system, tag: "DISCONN", message: "User requested VPN disconnect. Closing SSH2 tunnel...")
        vpn.stop()
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
}

private enum VPNProfileStore {
    nonisolated(unsafe) private static let defaults = UserDefaults(suiteName: "group.com.sshtunnel.shared") ?? .standard
    private static let key = "vpn.profile.metadata"

    static func load() -> VPNProfile {
        guard let data = defaults.data(forKey: key), let stored = try? JSONDecoder().decode(StoredProfile.self, from: data) else {
            return VPNProfile(host: "", port: 22, username: "", password: "", privateKey: "", hostKey: "")
        }
        return VPNProfile(host: stored.host, port: stored.port, username: stored.username, password: "", privateKey: "", hostKey: stored.hostKey)
    }

    static func save(_ profile: VPNProfile) {
        let stored = StoredProfile(host: profile.host, port: profile.port, username: profile.username, hostKey: profile.hostKey)
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: key) }
    }

    private struct StoredProfile: Codable {
        let host: String
        let port: Int
        let username: String
        let hostKey: String
    }
}

private final class VPNController {
    private let manager = NETunnelProviderManager()

    func start(profile: VPNProfile, completion: @escaping (Error?) -> Void) {
        manager.loadFromPreferences { [manager] error in
            guard error == nil else { completion(error); return }
            let configuration = NETunnelProviderProtocol()
            configuration.providerBundleIdentifier = "com.sshtunnel.app.packet-tunnel"
            configuration.serverAddress = profile.host
            configuration.includeAllNetworks = true
            configuration.enforceRoutes = true
            let passwordKey = "vps:\(profile.host):\(profile.username)"
            do {
                if !profile.password.isEmpty { try KeychainStore.save(password: profile.password, account: passwordKey) }
            } catch { completion(error); return }
            var providerConfiguration: [String: Any] = [
                "host": profile.host, "port": profile.port, "username": profile.username,
                "hostKey": profile.hostKey
            ]
            if !profile.dnsServers.isEmpty {
                providerConfiguration["dnsServers"] = profile.dnsServers
            }
            if !profile.password.isEmpty || KeychainStore.contains(account: passwordKey) {
                providerConfiguration["passwordKey"] = passwordKey
            }
            if !profile.privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                do {
                    let seed = try SSHPrivateKeyImporter.canonicalSeed(from: Data(profile.privateKey.utf8))
                    let privateKeyKey = "vps-key:\(profile.host):\(profile.username)"
                    try KeychainStore.save(password: seed.base64EncodedString(), account: privateKeyKey)
                    providerConfiguration["privateKeyKey"] = privateKeyKey
                } catch { completion(error); return }
            }
            let privateKeyKey = "vps-key:\(profile.host):\(profile.username)"
            if KeychainStore.contains(account: privateKeyKey) {
                providerConfiguration["privateKeyKey"] = privateKeyKey
            }
            VPNProfileStore.save(profile)
            configuration.providerConfiguration = providerConfiguration
            manager.protocolConfiguration = configuration
            manager.localizedDescription = "SSH2VPN"
            manager.isEnabled = true
            manager.saveToPreferences { error in
                guard error == nil else { completion(error); return }
                do { try manager.connection.startVPNTunnel(); completion(nil) }
                catch { completion(error) }
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
