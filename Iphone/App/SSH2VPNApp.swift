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
    @Published var profile = VPNProfileStore.load()
    private let vpn = VPNController()
    private var statusObserver: NSObjectProtocol?

    init() {
        statusObserver = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] note in
            guard let connection = note.object as? NEVPNConnection else { return }
            switch connection.status {
            case .connecting, .reasserting: self?.connection = .connecting
            case .connected: self?.connection = .connected
            case .disconnecting, .disconnected, .invalid: self?.connection = .disconnected
            @unknown default: self?.connection = .failed("Unknown VPN state")
            }
        }
    }

    var copy: AppCopy { AppCopy(language: selectedLanguage ?? .english) }

    var needsLanguageSelection: Bool { selectedLanguage == nil }

    func choose(_ language: AppLanguage) {
        selectedLanguage = language
        LanguageStore.current = language
    }

    func connect() {
        connection = .connecting
        vpn.start(profile: profile) { [weak self] error in
            if let error { self?.connection = .failed(error.localizedDescription) }
        }
    }

    func disconnect() { vpn.stop() }
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
