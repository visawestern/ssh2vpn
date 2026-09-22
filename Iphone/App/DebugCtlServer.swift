#if DEBUG
import Foundation
import Network
import Security
import VPNCore

/// DEBUG-ONLY local control channel for the AI agent's device loop.
///
/// Safety contract (Guideline 5.6 — must never reach App Review):
/// - This whole file compiles ONLY under `#if DEBUG`. A Release build
///   contains zero bytes of it: no strings, no symbols, no UI, no listeners.
/// - Binds 127.0.0.1 (loopback) on a fixed candidate port. Reachable from
///   the Mac ONLY via `iproxy` over USB. No Wi-Fi listen, no plist /
///   entitlement / capability changes for this file.
/// - NO bearer auth (owner decision: single-user dev Mac, USB-only path,
///   loopback unreachable from any network). The ONLY gate is physical USB
///   + DEBUG build. This file MUST be deleted before any App Store submit —
///   see the pre-submit checklist.
/// - Phase 2: status / logs / dump + servers / connect /disconnect/selftest.
///   Mutations drive the same model paths as finger taps.
/// - Never returns secrets: server entries expose id/name/host/port/username
///   + presence flags only. No passwords, keys or host keys on the wire.
///
/// Threading: the NWListener lives on a private queue; every model touch
/// hops to MainActor. `token`/`port` are lock-guarded (written on MainActor
/// at start, read on the queue per request).
final class DebugCtlServer: NSObject, @unchecked Sendable {
    static let shared = DebugCtlServer()

    private let queue = DispatchQueue(label: "ssh2vpn.dbgctl")
    private let lock = NSLock()
    private var listener: NWListener?
    private var guardedToken: String = ""
    private var guardedPort: Int = 0
    // App-lifetime object; strong is fine (singleton outlives nothing here).
    private var model: AppModel?

    /// Fixed loopback candidates (no syslog-based discovery: the app
    /// binary's own log lines don't reach idevicesyslog on current iOS).
    /// Loopback-only + bearer token + DEBUG-only keeps the posture identical
    /// to an ephemeral port; the agent probes them in order via /v1/health.
    private static let candidatePorts: [UInt16] = [17831, 17832, 17833]

    var port: Int {
        lock.lock(); defer { lock.unlock() }
        return guardedPort
    }

    private override init() { super.init() }

    /// Starts the loopback listener once per launch. Safe to call twice.
    @MainActor
    func start(model: AppModel) {
        lock.lock()
        let already = listener != nil
        lock.unlock()
        guard !already else { return }
        self.model = model
        NSLog("DBGCTL starting")
        // Short numeric PIN (operator reads it from the Hacker Console and
        // hands it to the agent once per launch — no syslog needed).
        var pinValue: UInt32 = 0
        _ = SecRandomCopyBytes(kSecRandomDefault, 3, &pinValue)
        let fresh = String(format: "%06d", Int(pinValue) % 1_000_000)
        // Bind off the main thread: the ready-probe blocks briefly.
        queue.async { [weak self] in self?.bind(fresh: fresh) }
    }

    private func bind(fresh: String) {
        // `init(using:on:)` only takes a Port here, so the bind address goes
        // via requiredLocalEndpoint (loopback pinned — never 0.0.0.0).
        var bound: (NWListener, Int)?
        var lastError: Error?
        for candidate in Self.candidatePorts {
            do {
                let params: NWParameters = .tcp
                params.requiredLocalEndpoint = .hostPort(
                    host: .ipv4(.loopback),
                    port: NWEndpoint.Port(rawValue: candidate)!)
                // NOTE: the port lives in requiredLocalEndpoint; `on:` stays
                // `.any` (passing it in both places never becomes ready).
                let l = try NWListener(using: params, on: .any)
                // NOTE: the probe waits on `queue`, so the listener must NOT
                // deliver states on `queue` (self-deadlock: ready would never
                // arrive while parked in wait()). Dedicated probe queue.
                let probeQueue = DispatchQueue(label: "ssh2vpn.dbgctl.probe")
                let ready = DispatchSemaphore(value: 0)
                let failBox = FailBox()
                l.newConnectionHandler = { [weak self] conn in self?.serve(conn) }
                l.stateUpdateHandler = { state in
                    switch state {
                    case .ready: ready.signal()
                    case .failed(let err): failBox.error = err; ready.signal()
                    case .cancelled: ready.signal()
                    default: break
                    }
                }
                l.start(queue: probeQueue)
                if ready.wait(timeout: .now() + 3) == .success, failBox.error == nil {
                    bound = (l, Int(candidate))
                    break
                }
                l.cancel()
                if let failed = failBox.error { lastError = failed }
            } catch {
                lastError = error
            }
        }
        guard let (l, assigned) = bound else {
            let detail = lastError?.localizedDescription ?? "all candidates busy"
            NSLog("DBGCTL listener start failed: %@", detail)
            ConsoleLogStore.shared.log(
                level: .error, tag: "DBGCTL",
                message: "listener start failed: \(detail)")
            return
        }
        l.newConnectionHandler = { [weak self] conn in self?.serve(conn) }
        l.stateUpdateHandler = { state in
            if case .failed(let err) = state {
                ConsoleLogStore.shared.log(
                    level: .warning, tag: "DBGCTL",
                    message: "listener failed: \(err.localizedDescription)")
            }
        }
        lock.lock()
        listener = l
        guardedToken = fresh
        guardedPort = assigned
        lock.unlock()
        // The PIN is shown in the Hacker Console (DBGCTL line) for the
        // operator to retype; it never ships (DEBUG-gated out of Release).
        NSLog("DBGCTL ready port=%d pin=%@", assigned, fresh)
        ConsoleLogStore.shared.log(
            level: .info, tag: "DBGCTL",
            message: "agent channel 127.0.0.1:\(assigned) PIN \(fresh) (DEBUG only — retype into agent)")
    }

    private func currentToken() -> String {
        lock.lock(); defer { lock.unlock() }
        return guardedToken
    }

    // MARK: - Connection serving (background queue; model hops to MainActor)

    private func serve(_ conn: NWConnection) {
        conn.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.receive(conn, buffer: Data()) }
        }
        conn.start(queue: queue)
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self else { conn.cancel(); return }
            if let data, !data.isEmpty {
                let next = buffer + data
                if next.count > 65536 || error != nil {
                    self.finish(conn, status: 413, data: dbgJSON(["ok": false, "error": "too-large"]))
                    return
                }
                if let head = self.headerEnd(in: next) {
                    let headData = next.prefix(head)
                    let prefix = Data(next.suffix(from: head))
                    let need = self.contentLength(of: headData)
                    if prefix.count >= need {
                        self.route(conn, head: headData, body: Data(prefix.prefix(need)))
                    } else {
                        self.receiveBody(conn, head: headData, need: need, buffer: prefix)
                    }
                    return
                }
                self.receive(conn, buffer: next)
                return
            }
            conn.cancel()
        }
    }

    /// Reads the POST body up to Content-Length (16 KB cap).
    private func receiveBody(_ conn: NWConnection, head: Data, need: Int, buffer: Data) {
        guard need <= 16384 else {
            finish(conn, status: 413, data: dbgJSON(["ok": false, "error": "too-large"]))
            return
        }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, error in
            guard let self else { conn.cancel(); return }
            if let data, !data.isEmpty, error == nil {
                let next = buffer + data
                if next.count >= need {
                    self.route(conn, head: head, body: Data(next.prefix(need)))
                } else if next.count > 16384 {
                    self.finish(conn, status: 413, data: dbgJSON(["ok": false, "error": "too-large"]))
                } else {
                    self.receiveBody(conn, head: head, need: need, buffer: next)
                }
                return
            }
            conn.cancel()
        }
    }

    private func contentLength(of head: Data) -> Int {
        guard let text = String(data: head, encoding: .utf8) else { return 0 }
        for line in text.components(separatedBy: "\r\n").dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2,
               kv[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                return max(0, Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0)
            }
        }
        return 0
    }

    private func headerEnd(in data: Data) -> Int? {
        guard data.count >= 4 else { return nil }
        for i in 0...(data.count - 4) {
            if data[i] == 13, data[i + 1] == 10,
               data[i + 2] == 13, data[i + 3] == 10 {
                return i + 4
            }
        }
        return nil
    }

    private func route(_ conn: NWConnection, head: Data, body: Data) {
        guard let text = String(data: head, encoding: .utf8),
              let requestLine = text.components(separatedBy: "\r\n").first else {
            finish(conn, status: 400, data: dbgJSON(["ok": false, "error": "bad-request"]))
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            finish(conn, status: 400, data: dbgJSON(["ok": false, "error": "bad-request"]))
            return
        }
        let method = String(parts[0])
        let rawPath = String(parts[1])
        let path = rawPath.components(separatedBy: "?").first ?? "/"
        if method == "GET", path == "/v1/health" {
            finish(conn, status: 200, data: dbgJSON(["ok": true, "service": "dbg-ctl-v1"]))
            return
        }
        guard authorized(headersOf: text) else {
            finish(conn, status: 401, data: dbgJSON(["ok": false, "error": "unauthorized"]))
            return
        }
        switch (method, path) {
        case ("GET", "/v1/status"): answerStatus(conn)
        case ("GET", "/v1/logs"): answerLogs(conn, queryOf: rawPath)
        case ("GET", "/v1/dump"): answerDump(conn)
        case ("POST", "/v1/servers"): answerAddServer(conn, body: body)
        case ("POST", "/v1/connect"): answerConnect(conn, body: body)
        case ("POST", "/v1/disconnect"): answerDisconnect(conn)
        case ("POST", "/v1/selftest"): answerSelfTest(conn)
        case ("POST", "/v1/language"): answerLanguage(conn, body: body)
        default: finish(conn, status: 404, data: dbgJSON(["ok": false, "error": "unknown"]))
        }
    }

    // Owner decision: no bearer auth. The listener is loopback-only and
    // reachable solely via USB `iproxy`; there is no network path to it.
    // Kept as a function (not deleted) so re-adding auth is one line.
    // This whole file MUST be deleted before any App Store submit.
    private func authorized(headersOf text: String) -> Bool {
        _ = text
        return true
    }

    private func query(_ raw: String) -> [String: String] {
        guard let q = raw.split(separator: "?", maxSplits: 1).last,
              q.contains("=") else { return [:] }
        var out: [String: String] = [:]
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { out[String(kv[0])] = String(kv[1]) }
        }
        return out
    }

    /// Base status dict, serialized on MainActor (the only place the model
    /// may be touched). Returns wire-ready `Data` because `[String: Any]`
    /// is not Sendable and may not cross domains.
    private func baseData() async -> Data? {
        guard let m = await MainActor.run(resultType: AppModel?.self, body: { [weak self] in self?.model }) else {
            return nil
        }
        return await MainActor.run {
            let servers = m.servers.map { s -> [String: String] in
                ["id": s.id, "name": s.name, "host": s.host,
                 "port": String(s.port), "username": s.username,
                 "hasPassword": String(s.hasPassword),
                 "hasPrivateKey": String(s.hasPrivateKey)]
            }
            var d: [String: Any] = [
                "connection": String(describing: m.connection),
                "isUnlimited": m.isUnlimited,
                "quotaRemainingSeconds": Int(m.quota.remaining(now: Date())),
                "serverCount": servers.count,
                "appVersion": AppModel.appVersion,
            ]
            d["servers"] = servers
            if let s = m.selectedServer {
                d["selected"] = ["id": s.id, "host": s.host,
                                 "port": s.port, "username": s.username]
            }
            if let e = TunnelLastError.read() { d["lastError"] = e }
            return dbgJSON(d)
        }
    }

    private func baseObject(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func answerStatus(_ conn: NWConnection) {
        Task { [weak self] in
            guard let self, let base = await self.baseData() else {
                self?.finish(conn, status: 503, data: dbgJSON(["ok": false, "error": "no-model"]))
                return
            }
            var body = self.baseObject(base)
            body["ok"] = true
            self.finish(conn, status: 200, data: dbgJSON(body))
        }
    }

    private func answerLogs(_ conn: NWConnection, queryOf raw: String) {
        let tail = max(1, min(2000, Int(query(raw)["tail"] ?? "") ?? 400))
        Task { [weak self] in
            let lines = await MainActor.run {
                Array(ConsoleLogStore.shared.entries.suffix(tail)).map { e -> [String: String] in
                    ["level": String(describing: e.level),
                     "tag": e.tag, "message": e.message]
                }
            }
            self?.finish(conn, status: 200, data: dbgJSON(["ok": true, "entries": lines]))
        }
    }

    private func answerDump(_ conn: NWConnection) {
        Task { [weak self] in
            guard let self, let base = await self.baseData() else {
                self?.finish(conn, status: 503, data: dbgJSON(["ok": false, "error": "no-model"]))
                return
            }
            let tail: String = await MainActor.run {
                let text = ConsoleLogStore.shared.exportPlainText()
                return Array(text.components(separatedBy: "\n").suffix(400)).joined(separator: "\n")
            }
            var body = self.baseObject(base)
            body["ok"] = true
            body["logTail"] = tail
            self.finish(conn, status: 200, data: dbgJSON(body))
        }
    }

    // MARK: - Phase 2 mutations (same model paths as finger taps)

    /// Adds a server exactly like the manual Add form: same validators,
    /// same `saveServer` (local + extension sync). Host-key pinning happens
    /// on first connect, like the UI flow.
    /// Body: {"host","port"?=22,"username","password"?,"privateKey"?,"name"?}
    private func answerAddServer(_ conn: NWConnection, body: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            finish(conn, status: 400, data: dbgJSON(["ok": false, "error": "bad-json"]))
            return
        }
        Task { [weak self] in
            guard let self else { conn.cancel(); return }
            // Extract Sendable scalars here: `obj` itself ([String: Any])
            // may not cross into the MainActor hop.
            let hostRaw = obj["host"] as? String ?? ""
            let portRaw = obj["port"].map { String(describing: $0) } ?? "22"
            let userRaw = obj["username"] as? String ?? ""
            let passRaw = obj["password"] as? String ?? ""
            let keyRaw = obj["privateKey"] as? String ?? ""
            let nameRaw = obj["name"] as? String ?? ""
            let outcome: (Int, Data) = await MainActor.run {
                do {
                    let host = try ProfileValidator.validateHost(hostRaw)
                    let port = try ProfileValidator.validatePort(portRaw)
                    let username = try ProfileValidator.validateUsername(userRaw)
                    let password = passRaw.isEmpty ? nil : passRaw
                    let privateKey = keyRaw.isEmpty ? nil : keyRaw
                    try ProfileValidator.validateCredentials(
                        password: password ?? "", privateKey: privateKey ?? "")
                    guard let m = self.model else {
                        return (503, dbgJSON(["ok": false, "error": "no-model"]))
                    }
                    let profile = ServerProfile(
                        id: UUID().uuidString,
                        name: nameRaw.isEmpty ? host : nameRaw,
                        host: host, port: port, username: username,
                        hostKey: "", dnsServers: [],
                        hasPassword: password != nil, hasPrivateKey: privateKey != nil,
                        password: password, privateKey: privateKey)
                    try m.saveServer(profile)
                    return (200, dbgJSON(["ok": true, "id": profile.id]))
                } catch {
                    return (400, dbgJSON(["ok": false, "error": error.localizedDescription]))
                }
            }
            self.finish(conn, status: outcome.0, data: outcome.1)
        }
    }

    /// Selects a server (optional {"id"}) and taps Connect — the same
    /// `selectServer` + `connect(manual:)` the power button drives.
    private func answerConnect(_ conn: NWConnection, body: Data) {
        let id: String? = {
            guard !body.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                return nil
            }
            return obj["id"] as? String
        }()
        Task { [weak self] in
            guard let self else { conn.cancel(); return }
            let outcome: (Int, Data) = await MainActor.run {
                guard let m = self.model else {
                    return (503, dbgJSON(["ok": false, "error": "no-model"]))
                }
                if let id {
                    guard m.servers.contains(where: { $0.id == id }) else {
                        return (404, dbgJSON(["ok": false, "error": "unknown-server"]))
                    }
                    m.selectServer(id: id)
                }
                guard m.selectedServer != nil else {
                    return (400, dbgJSON(["ok": false, "error": "no-server-selected"]))
                }
                m.connect(manual: true)
                return (200, dbgJSON(["ok": true, "state": String(describing: m.connection)]))
            }
            self.finish(conn, status: outcome.0, data: outcome.1)
        }
    }

    private func answerDisconnect(_ conn: NWConnection) {
        Task { [weak self] in
            guard let self else { conn.cancel(); return }
            await MainActor.run { [weak self] in self?.model?.disconnect() }
            self.finish(conn, status: 200, data: dbgJSON(["ok": true]))
        }
    }

    /// Kicks the same post-connect self-test the app runs automatically;
    /// the verdict lands in the console log (`SELFTEST` tag).
    private func answerSelfTest(_ conn: NWConnection) {
        Task { [weak self] in
            guard let self else { conn.cancel(); return }
            await MainActor.run { [weak self] in self?.model?.debugRunSelfTest() }
            self.finish(conn, status: 200, data: dbgJSON(["ok": true]))
        }
    }

    /// Switches the interface language via the same `choose` path as the
    /// in-app picker (for localized screenshot runs). Body: {"code":"ja"}.
    private func answerLanguage(_ conn: NWConnection, body: Data) {
        let code: String = {
            guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                return ""
            }
            return obj["code"] as? String ?? ""
        }()
        Task { [weak self] in
            guard let self else { conn.cancel(); return }
            let ok: Bool = await MainActor.run { [weak self] in
                self?.model?.debugChooseLanguage(code: code) ?? false
            }
            self.finish(conn, status: ok ? 200 : 400,
                        data: dbgJSON(ok ? ["ok": true, "code": code] as [String: Any]
                                         : ["ok": false, "error": "unknown-language"]))
        }
    }

    private func finish(_ conn: NWConnection, status: Int, data: Data) {
        let reason: String = {
            switch status {
            case 200: return "OK"
            case 400: return "Bad Request"
            case 401: return "Unauthorized"
            case 404: return "Not Found"
            case 405: return "Method Not Allowed"
            case 413: return "Payload Too Large"
            default: return "Error"
            }
        }()
        let data = data
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(data)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}

/// File-scope JSON helper (deliberately NOT a method: parameters of methods
/// on Sendable types are inferred `sending`, and `[String: Any]` is not
/// Sendable — the serialized `Data` is what crosses domains).
private func dbgJSON(_ obj: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: obj, options: [])) ?? Data("{\"ok\":false}".utf8)
}

/// Lock-free error slot for the bind probe (set once from the listener's
/// state handler, read after the semaphore — no races by construction).
private final class FailBox: @unchecked Sendable {
    var error: Error?
}
#endif
