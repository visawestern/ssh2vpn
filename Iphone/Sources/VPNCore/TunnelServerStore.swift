import Foundation

/// One SSH server the user can connect through. The extension persists the
/// full list including secrets; the app only ever sees these via the API which
/// strips secrets and exposes only `hasPassword` / `hasPrivateKey` flags.
public struct ServerProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var hostKey: String
    public var dnsServers: [String]

    // Presence flags only — these are what the app sees. The actual values are
    // stored by the extension and never returned over the message channel.
    public var hasPassword: Bool
    public var hasPrivateKey: Bool

    public var password: String?
    public var privateKey: String?

    public init(
        id: String, name: String, host: String, port: Int, username: String,
        hostKey: String, dnsServers: [String], hasPassword: Bool, hasPrivateKey: Bool,
        password: String? = nil, privateKey: String? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.hostKey = hostKey
        self.dnsServers = dnsServers
        self.hasPassword = hasPassword
        self.hasPrivateKey = hasPrivateKey
        self.password = password
        self.privateKey = privateKey
    }

    /// Resilient decode: any missing field falls back to a safe default so a
    /// partial payload from the extension never crashes the app.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        hostKey = try c.decodeIfPresent(String.self, forKey: .hostKey) ?? ""
        dnsServers = try c.decodeIfPresent([String].self, forKey: .dnsServers) ?? []
        hasPassword = try c.decodeIfPresent(Bool.self, forKey: .hasPassword) ?? false
        hasPrivateKey = try c.decodeIfPresent(Bool.self, forKey: .hasPrivateKey) ?? false
        password = try c.decodeIfPresent(String.self, forKey: .password)
        privateKey = try c.decodeIfPresent(String.self, forKey: .privateKey)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, hostKey, dnsServers
        case hasPassword, hasPrivateKey, password, privateKey
    }
}

/// Extension-owned persistence for the server list + selected id.
///
/// Lives entirely in the extension's UserDefaults container (no app-group). The
/// app never reads these defaults directly — it talks to the extension over the
/// app-message channel and receives a secrets-stripped view.
public struct TunnelServerStore {
    private let defaults: UserDefaults

    private static let serversKey = "tunnel.servers.v1"
    private static let selectedKey = "tunnel.selected.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Server list

    public func loadAll() -> [ServerProfile] {
        guard let data = defaults.data(forKey: Self.serversKey),
              let servers = try? JSONDecoder().decode([ServerProfile].self, from: data) else {
            return []
        }
        return servers
    }

    public func load(id: String) -> ServerProfile? {
        loadAll().first { $0.id == id }
    }

    /// Insert a new profile or replace the one with the same id.
    public func save(_ profile: ServerProfile) {
        var all = loadAll()
        if let idx = all.firstIndex(where: { $0.id == profile.id }) {
            all[idx] = profile
        } else {
            all.append(profile)
        }
        persist(all)
    }

    public func delete(id: String) {
        let filtered = loadAll().filter { $0.id != id }
        persist(filtered)
    }

    // MARK: - Selected id

    public func selectedID() -> String? {
        defaults.string(forKey: Self.selectedKey)
    }

    public func select(id: String) {
        defaults.set(id, forKey: Self.selectedKey)
    }

    // MARK: - One-time dedupe flag

    private static let dedupeKey = "tunnel.servers.deduped.v1"

    /// True until duplicate records were cleaned once. Per-container, so the
    /// app and the extension each run their own one-time pass.
    public func needsDedupe() -> Bool {
        !defaults.bool(forKey: Self.dedupeKey)
    }

    public func markDeduped() {
        defaults.set(true, forKey: Self.dedupeKey)
    }

    // MARK: - Clear

    public func clear() {
        defaults.removeObject(forKey: Self.serversKey)
        defaults.removeObject(forKey: Self.selectedKey)
    }

    // MARK: - Private

    private func persist(_ servers: [ServerProfile]) {
        if let data = try? JSONEncoder().encode(servers) {
            defaults.set(data, forKey: Self.serversKey)
        }
    }
}
