import Foundation

/// Pure JSON command router that lives in the extension.
///
/// The extension's `handleAppMessage` feeds the raw request `Data` here and
/// sends back the response `Data`. Everything is JSON:
///   request  = {"cmd": "...", "args": {...}}
///   response = {"ok": bool, "data": {...}}
///
/// The critical guarantee: `serverList` / `serverGet` strip secrets and only
/// return `hasPassword` / `hasPrivateKey` presence flags.
public struct TunnelAppMessageRouter {
    public var serverStore: TunnelServerStore
    public var statusProvider: () -> [String: String]
    public var errorProvider: () -> [String: String]
    public var logProvider: () -> [ConsoleLogEntry]

    public init(
        serverStore: TunnelServerStore,
        statusProvider: @escaping () -> [String: String],
        errorProvider: @escaping () -> [String: String],
        logProvider: @escaping () -> [ConsoleLogEntry] = { [] }
    ) {
        self.serverStore = serverStore
        self.statusProvider = statusProvider
        self.errorProvider = errorProvider
        self.logProvider = logProvider
    }

    // MARK: - Request / response types

    private struct Request: Decodable {
        var cmd: String
        var args: [String: Any]?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            cmd = try c.decode(String.self, forKey: .cmd)
            // Decode args as a loose JSON dictionary.
            if c.contains(.args), let argsValue = try? c.decode([String: JSONValue].self, forKey: .args) {
                args = argsValue.mapValues { $0.value }
            }
        }

        enum CodingKeys: String, CodingKey { case cmd, args }
    }

    private struct Response: Encodable {
        var ok: Bool
        var data: [String: String]
    }

    // MARK: - Public API

    /// Handles one command and returns the encoded response, or nil if the
    /// request could not be decoded at all.
    public func handle(_ messageData: Data) -> Data? {
        guard let req = try? JSONDecoder().decode(Request.self, from: messageData) else {
            let rsp = Response(ok: false, data: ["error": "malformed request"])
            return try? JSONEncoder().encode(rsp)
        }
        let rsp = dispatch(cmd: req.cmd, args: req.args)
        return try? JSONEncoder().encode(rsp)
    }

    // MARK: - Dispatch

    private func dispatch(cmd: String, args: [String: Any]?) -> Response {
        switch cmd {
        case "status":
            return Response(ok: true, data: statusProvider())
        case "lastError":
            return Response(ok: true, data: errorProvider())
        case "serverList":
            return handleServerList()
        case "serverGet":
            return handleServerGet(args: args)
        case "serverSet":
            return handleServerSet(args: args)
        case "serverDelete":
            return handleServerDelete(args: args)
        case "serverSelect":
            return handleServerSelect(args: args)
        case "logs":
            return handleLogs(args: args)
        default:
            return Response(ok: false, data: ["error": "unknown cmd: \(cmd)"])
        }
    }

    // MARK: - Server list

    private func handleServerList() -> Response {
        let secretsStripped = serverStore.loadAll().map { $0.withoutSecrets() }
        let json = encodeJSON(secretsStripped) ?? "[]"
        var data: [String: String] = ["servers": json]
        if let selected = serverStore.selectedID() {
            data["selectedID"] = selected
        }
        return Response(ok: true, data: data)
    }

    private func handleServerGet(args: [String: Any]?) -> Response {
        guard let id = args?["id"] as? String, let profile = serverStore.load(id: id) else {
            return Response(ok: false, data: ["error": "server not found"])
        }
        let json = encodeJSON(profile.withoutSecrets()) ?? "{}"
        return Response(ok: true, data: ["server": json])
    }

    private func handleServerSet(args: [String: Any]?) -> Response {
        guard let args,
              let data = try? JSONSerialization.data(withJSONObject: args),
              let incoming = try? JSONDecoder().decode(ServerProfile.self, from: data) else {
            return Response(ok: false, data: ["error": "invalid server payload"])
        }
        // Field-level merge: the app cannot read secrets back, so an omitted
        // field means "keep the existing value". Only fields present in the
        // args dict are applied; everything else is preserved from store.
        let merged: ServerProfile
        if let existing = serverStore.load(id: incoming.id) {
            merged = merge(existing: existing, incoming: incoming, args: args)
        } else {
            merged = incoming
        }
        serverStore.save(merged)
        return Response(ok: true, data: ["stored": "true"])
    }

    /// Merges incoming fields over the existing profile. A field is only
    /// overwritten when its key is present in the args dict — this lets the app
    /// edit non-secret fields without accidentally clearing the saved secrets
    /// (which it cannot read back). Presence flags are always recomputed from
    /// the actual secret values, never trusted from the app.
    private func merge(existing: ServerProfile, incoming: ServerProfile, args: [String: Any]) -> ServerProfile {
        var r = existing
        if args.keys.contains("name") { r.name = incoming.name }
        if args.keys.contains("host") { r.host = incoming.host }
        if args.keys.contains("port") { r.port = incoming.port }
        if args.keys.contains("username") { r.username = incoming.username }
        if args.keys.contains("hostKey") { r.hostKey = incoming.hostKey }
        if args.keys.contains("dnsServers") { r.dnsServers = incoming.dnsServers }
        if args.keys.contains("password") { r.password = incoming.password }
        if args.keys.contains("privateKey") { r.privateKey = incoming.privateKey }
        // Recompute presence flags from actual values — the app cannot read
        // secrets back, so its flags would always be false on edit.
        r.hasPassword = r.password?.isEmpty == false
        r.hasPrivateKey = r.privateKey?.isEmpty == false
        return r
    }

    private func handleServerDelete(args: [String: Any]?) -> Response {
        guard let id = args?["id"] as? String else {
            return Response(ok: false, data: ["error": "missing id"])
        }
        guard serverStore.load(id: id) != nil else {
            return Response(ok: false, data: ["error": "server not found"])
        }
        serverStore.delete(id: id)
        return Response(ok: true, data: ["deleted": "true"])
    }

    private func handleServerSelect(args: [String: Any]?) -> Response {
        guard let id = args?["id"] as? String else {
            return Response(ok: false, data: ["error": "missing id"])
        }
        guard serverStore.load(id: id) != nil else {
            return Response(ok: false, data: ["error": "server not found"])
        }
        serverStore.select(id: id)
        return Response(ok: true, data: ["selected": "true"])
    }

    // MARK: - Extension log bridge

    /// Returns the extension's recent console lines (newest last) as JSON.
    /// This is the only log bridge that works without an app-group: the app
    /// polls it while connecting and once more on disconnect. Entries are
    /// pre-sanitized at log() time, so no secrets leak through here.
    private func handleLogs(args: [String: Any]?) -> Response {
        let limit = (args?["limit"] as? Int) ?? 200
        let window = logProvider().suffix(max(0, limit))
        guard let data = try? JSONEncoder().encode(Array(window)),
              let json = String(data: data, encoding: .utf8) else {
            return Response(ok: false, data: ["error": "log encode failed"])
        }
        return Response(ok: true, data: ["entries": json])
    }

    // MARK: - Helpers

    private func encodeJSON<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Secret stripping

private extension ServerProfile {
    /// Returns a copy with all secrets removed — only presence flags remain.
    func withoutSecrets() -> ServerProfile {
        ServerProfile(
            id: id, name: name, host: host, port: port, username: username,
            hostKey: hostKey, dnsServers: dnsServers,
            hasPassword: hasPassword, hasPrivateKey: hasPrivateKey,
            password: nil, privateKey: nil
        )
    }
}

// MARK: - Loose JSON decoding

/// Decodes any JSON value into `Any` so we can accept arbitrary `args` without
/// failing on fields the router doesn't care about.
private enum JSONValue: Decodable {
    case string(String), int(Int), double(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    var value: Any {
        switch self {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .object(let o): return o.mapValues { $0.value }
        case .array(let a): return a.map { $0.value }
        case .null: return NSNull()
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value")
    }
}
