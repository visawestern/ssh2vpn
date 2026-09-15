import Foundation

/// One SSH server the user can connect through. The extension persists the
/// full list including secrets; the app only ever sees these via the API which
/// strips secrets and exposes only `hasPassword` / `hasPrivateKey` flags.
public struct ServerProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// Optional user-given alias shown instead of the IP when set.
    /// Nil / blank means "no alias" — UI falls back to host:port + username chip.
    public var label: String?
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
        password: String? = nil, privateKey: String? = nil, label: String? = nil
    ) {
        self.id = id
        self.name = name
        self.label = Self.normalizedLabel(label)
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
        label = Self.normalizedLabel(try c.decodeIfPresent(String.self, forKey: .label))
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
        case id, name, label, host, port, username, hostKey, dnsServers
        case hasPassword, hasPrivateKey, password, privateKey
    }

    // MARK: - Label helpers

    /// Sanitizes the raw label (see TextInputSanitizer): strips zero-width /
    /// bidi / control / private-use garbage, collapses whitespace, caps
    /// length. Blank or fully-stripped input becomes nil so the UI can treat
    /// "no alias" as a single nil check. Runs on init AND on decode, so
    /// garbage stored by an older build is cleaned at load time too.
    public static func normalizedLabel(_ raw: String?) -> String? {
        TextInputSanitizer.sanitizeLabel(raw)
    }

    /// Non-nil alias for display, or nil when the server has no alias.
    public var displayLabel: String? {
        Self.normalizedLabel(label)
    }

    /// True when the user gave this server a custom alias.
    public var hasCustomLabel: Bool { displayLabel != nil }

    /// Subtitle for lists: alias when set, otherwise the classic host:port.
    /// When there is no alias the caller should also render the username chip.
    public var displayAddress: String {
        displayLabel ?? "\(host):\(port)"
    }
}

/// Extension-owned persistence for the server list + selected id.
///
/// Lives entirely in the extension's UserDefaults container (no app-group). The
/// app never reads these defaults directly — it talks to the extension over the
/// app-message channel and receives a secrets-stripped view.
public struct TunnelServerStore {
    private let defaults: UserDefaults
    private let vault: any CredentialVault

    private static let serversKey = "tunnel.servers.v1"
    private static let selectedKey = "tunnel.selected.v1"

    public init(defaults: UserDefaults = .standard, vault: any CredentialVault = KeychainCredentialVault()) {
        self.defaults = defaults
        self.vault = vault
    }

    // MARK: - Server list

    public func loadAll() -> [ServerProfile] {
        guard let data = defaults.data(forKey: Self.serversKey),
              let servers = try? JSONDecoder().decode([ServerProfile].self, from: data) else {
            return []
        }
        var hydrated = servers
        var migrated = false
        for index in hydrated.indices {
            let account = "profile:" + hydrated[index].id
            if hydrated[index].password != nil || hydrated[index].privateKey != nil {
                // Preserve legacy records if Keychain is temporarily inaccessible.
                do {
                    let secret = ServerSecrets(password: hydrated[index].password, privateKey: hydrated[index].privateKey)
                    try vault.write(JSONEncoder().encode(secret), account: account)
                    migrated = true
                } catch { return servers }
            } else if let data = try? vault.read(account), let secret = try? JSONDecoder().decode(ServerSecrets.self, from: data) {
                hydrated[index].password = secret.password
                hydrated[index].privateKey = secret.privateKey
            }
        }
        if migrated { persist(hydrated) }
        return hydrated
    }

    public func load(id: String) -> ServerProfile? {
        loadAll().first { $0.id == id }
    }

    /// Insert a new profile or replace the one with the same id.
    @discardableResult
    public func save(_ profile: ServerProfile) -> Bool {
        var all = loadAll()
        do {
            // Do not overwrite unavailable secrets when an edit keeps existing credentials.
            let account = "profile:" + profile.id
            var secret = ServerSecrets(password: profile.password, privateKey: profile.privateKey)
            if (profile.hasPassword && secret.password == nil) || (profile.hasPrivateKey && secret.privateKey == nil) {
                guard let data = try vault.read(account) else { return false }
                let previous = try JSONDecoder().decode(ServerSecrets.self, from: data)
                if profile.hasPassword && secret.password == nil { secret.password = previous.password }
                if profile.hasPrivateKey && secret.privateKey == nil { secret.privateKey = previous.privateKey }
            }
            try vault.write(JSONEncoder().encode(secret), account: account)
        } catch { return false }
        if let idx = all.firstIndex(where: { $0.id == profile.id }) {
            all[idx] = profile
        } else {
            all.append(profile)
        }
        return persist(all)
    }

    public func delete(id: String) {
        let all = loadAll()
        guard (try? vault.remove("profile:" + id)) != nil else { return }
        let filtered = all.filter { $0.id != id }
        if let deleted = all.first(where: { $0.id == id }),
           !filtered.contains(where: { $0.host == deleted.host && $0.port == deleted.port && $0.username == deleted.username }) {
            try? vault.remove(ServerSecrets.account(host: deleted.host, port: deleted.port, username: deleted.username))
        }
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
        for profile in loadAll() { try? vault.remove("profile:" + profile.id) }
        defaults.removeObject(forKey: Self.serversKey)
        defaults.removeObject(forKey: Self.selectedKey)
    }

    // MARK: - Private

    @discardableResult
    private func persist(_ servers: [ServerProfile]) -> Bool {
        do {
            for profile in servers where profile.password != nil || profile.privateKey != nil {
                try vault.write(JSONEncoder().encode(ServerSecrets(password: profile.password, privateKey: profile.privateKey)), account: "profile:" + profile.id)
            }
        } catch { return false }
        let publicProfiles = servers.map { profile in
            var clean = profile
            clean.password = nil
            clean.privateKey = nil
            return clean
        }
        if let data = try? JSONEncoder().encode(publicProfiles) {
            defaults.set(data, forKey: Self.serversKey)
            return true
        }
        return false
    }
}
