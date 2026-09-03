import Foundation
import Network
import NetworkExtension
import VPNCore

/// Dual-write for extension diagnostics: device console (NSLog, visible in
/// sysdiagnose) + the extension's in-memory ConsoleLogStore, which the app
/// pulls over the message API (`logs` command) — the only log bridge that
/// works without an app-group entitlement.
private func elog(_ level: ConsoleLogLevel, _ tag: String, _ message: String) {
    NSLog("[SSH2VPN][\(tag)] \(message)")
    ConsoleLogStore.shared.log(level: level, tag: tag, message: message)
}

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var packetLoop: PacketTunnelPacketLoop?
    private var transport: SSHPacketTunnelTransport?
    // Latest runtime failure surfaced by the tunnel (auth, transport, config,
    // probe). The app pulls it over this VPN's app-message channel.
    private var lastRuntimeError: String?
    private var tunnelPhase: String = "idle"
    // Why the tunnel last went down (NEProviderStopReason decoded). Empty
    // until the first stop; surfaced via the status API for the app dump.
    private var lastStopReason: String = "none"
    // Guards the start sequence: a second startTunnel while one is already in
    // flight means something is restacking attempts (retry loop / double tap).
    private var startInFlight = false
    private var loopStartCompleted = false

    private let serverStore = TunnelServerStore()

    // MARK: - App <-> Extension message API
    //
    // The app talks to the extension through the official
    // NEPacketTunnelProvider app-message channel (works without any app-group
    // entitlement). Each request is a function call returning a response.
    // Wire format: JSON {"cmd":"...","args":{...}} -> {"ok":bool,"data":{...}}
    //
    // The pure dispatch logic lives in TunnelAppMessageRouter (VPNCore) and is
    // unit-tested there. This override just bridges the system callback to it.
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        let router = TunnelAppMessageRouter(
            serverStore: serverStore,
            statusProvider: { [weak self] in
                ["phase": self?.tunnelPhase ?? "idle",
                 "transport": self?.transport == nil ? "nil" : "set",
                 "stopReason": self?.lastStopReason ?? "none",
                 "packetsRead": "\(self?.packetLoop?.packetsRead ?? 0)",
                 "packetsWritten": "\(self?.packetLoop?.packetsWritten ?? 0)",
                 "sessions": "\(self?.transport?.sessionCount ?? 0)"]
            },
            errorProvider: { [weak self] in
                ["error": self?.lastRuntimeError ?? "none"]
            },
            logProvider: { ConsoleLogStore.shared.entries }
        )
        completionHandler?(router.handle(messageData))
    }

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        elog(.info, "TUNNEL", "startTunnel BEGIN")
        if startInFlight {
            elog(.warning, "TUNNEL", "startTunnel RE-ENTERED while a start is already in flight")
            lastRuntimeError = "startTunnel re-entered while previous start in flight"
        }
        startInFlight = true
        tunnelPhase = "begin"
        do {
            var providerConfiguration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
            elog(.info, "TUNNEL", "providerConfiguration keys: \(providerConfiguration?.keys.sorted() ?? [])")
            // The extension is the owner of the server list. If it has a
            // selected server saved, use that as the source of truth for the
            // tunnel (the app syncs the list over the message API), ignoring
            // what the system passed through.
            if let selectedID = serverStore.selectedID(),
               let selected = serverStore.load(id: selectedID) {
                var merged = providerConfiguration ?? [:]
                merged["host"] = selected.host
                merged["port"] = selected.port
                merged["username"] = selected.username
                merged["hostKey"] = selected.hostKey
                merged["dnsServers"] = selected.dnsServers
                if let pwd = selected.password, !pwd.isEmpty { merged["password"] = pwd }
                else { merged.removeValue(forKey: "password") }
                if let key = selected.privateKey, !key.isEmpty { merged["privateKey"] = key }
                else { merged.removeValue(forKey: "privateKey") }
                providerConfiguration = merged
                elog(.info, "TUNNEL", "using extension-owned server id=\(selectedID) host=\(selected.host) hasPassword=\(selected.hasPassword)")
            }
            let configuration = try TunnelConfiguration(providerConfiguration: providerConfiguration)
            tunnelPhase = "config"
            elog(.info, "TUNNEL", "TunnelConfiguration OK host=\(configuration.host) port=\(configuration.port) user=\(configuration.username) hasPassword=\(configuration.password != nil) hasPrivateKey=\(configuration.privateKey != nil) dns=\(configuration.dnsServers)")
            // Persist the effective config into the extension-owned store so a
            // copy survives here (used by the next start and by serverList
            // queries while the tunnel runs). Secrets live only in this store.
            // One-time hygiene first: earlier builds minted a fresh UUID per
            // connect whenever no server was selected, spawning duplicates.
            if serverStore.needsDedupe() {
                serverStore.markDeduped()
                let dupes = ServerDedupe.duplicateIDs(servers: serverStore.loadAll(), selectedID: serverStore.selectedID())
                for id in dupes { serverStore.delete(id: id) }
                if !dupes.isEmpty {
                    elog(.warning, "TUNNEL", "removed \(dupes.count) duplicate server record(s) (one-time hygiene)")
                }
            }
            // Reuse the selected record, else match by coordinates — never mint
            // a fresh UUID for a machine we already know.
            let persistID: String = {
                if let sel = serverStore.selectedID(), serverStore.load(id: sel) != nil { return sel }
                if let match = ServerDedupe.matchID(servers: serverStore.loadAll(), host: configuration.host, port: configuration.port, username: configuration.username) { return match }
                return UUID().uuidString
            }()
            var storedProfile = serverStore.load(id: persistID) ?? ServerProfile(
                id: persistID, name: configuration.host, host: configuration.host, port: configuration.port,
                username: configuration.username, hostKey: configuration.hostKey ?? "",
                dnsServers: configuration.dnsServers, hasPassword: false, hasPrivateKey: false)
            storedProfile.host = configuration.host
            storedProfile.port = configuration.port
            storedProfile.username = configuration.username
            storedProfile.hostKey = configuration.hostKey ?? ""
            storedProfile.dnsServers = configuration.dnsServers
            storedProfile.password = configuration.password
            storedProfile.privateKey = (providerConfiguration?["privateKey"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            storedProfile.hasPassword = storedProfile.password?.isEmpty == false
            storedProfile.hasPrivateKey = storedProfile.privateKey?.isEmpty == false
            serverStore.save(storedProfile)
            serverStore.select(id: persistID)
            // Resolve once and pin the whole tunnel to that result: the route
            // exclusions below must match the address the SSH socket actually
            // connects to, otherwise the tunnel can recursively carry it.
            let endpoint = try SSHEndpointResolver.resolve(configuration.host)
            tunnelPhase = "resolved"
            elog(.info, "TUNNEL", "endpoint resolved ipv4=\(endpoint.ipv4) ipv6=\(endpoint.ipv6)")
            // The device identity is persisted so a reconnect (and the gateway
            // broker socket) stays stable across tunnel restarts, while being
            // unique per install so two phones sharing one VPS never collide.
            let brokerID = Self.persistentDeviceIdentity()
            let device = try TunnelDevice.derive(brokerID: brokerID)
            tunnelPhase = "device"
            elog(.info, "TUNNEL", "device derived ipv4=\(device.ipv4Address) ipv6=\(device.ipv6Address)")
            let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: configuration.host)
            settings.ipv4Settings = NEIPv4Settings(addresses: [device.ipv4Address], subnetMasks: [TunnelDevice.v4SubnetMask])
            settings.ipv4Settings?.includedRoutes = [NEIPv4Route.default()]
            settings.ipv6Settings = NEIPv6Settings(addresses: [device.ipv6Address], networkPrefixLengths: [NSNumber(value: TunnelDevice.v6PrefixLength)])
            settings.ipv6Settings?.includedRoutes = [NEIPv6Route.default()]
            // Keep the SSH control channel outside the packet tunnel. Without
            // this host route the tunnel can recursively carry its own socket.
            if !endpoint.ipv4.isEmpty {
                settings.ipv4Settings?.excludedRoutes = endpoint.ipv4.map {
                    NEIPv4Route(destinationAddress: $0, subnetMask: "255.255.255.255")
                }
            }
            if !endpoint.ipv6.isEmpty {
                settings.ipv6Settings?.excludedRoutes = endpoint.ipv6.map {
                    NEIPv6Route(destinationAddress: $0, networkPrefixLength: 128)
                }
            }
            // DNS comes from the saved profile; when unset the system resolvers
            // are used so the tunnel never depends on a hardcoded third party.
            if !configuration.dnsServers.isEmpty {
                let dns = NEDNSSettings(servers: configuration.dnsServers)
                dns.matchDomains = [""]
                settings.dnsSettings = dns
            }
            elog(.info, "TUNNEL", "network settings built")

            let transport = try SSHPacketTunnelTransport(configuration: configuration, endpoint: endpoint, brokerID: brokerID, bundle: .main)
            self.transport = transport
            tunnelPhase = "transport"
            elog(.info, "TUNNEL", "transport initialized; calling setTunnelNetworkSettings")
            setTunnelNetworkSettings(settings) { [weak self] error in
                if let error {
                    elog(.error, "TUNNEL", "setTunnelNetworkSettings FAILED: \(error)")
                    self?.lastRuntimeError = "setTunnelNetworkSettings: \(error.localizedDescription)"
                } else {
                    elog(.info, "TUNNEL", "setTunnelNetworkSettings OK")
                    self?.tunnelPhase = "network-settings"
                }
                guard let self, error == nil else {
                    self?.startInFlight = false
                    completionHandler(error)
                    return
                }
                let loop = PacketTunnelPacketLoop(packetFlow: self.packetFlow, transport: transport)
                self.packetLoop = loop
                self.loopStartCompleted = false
                loop.start { [weak self] readyError in
                    self?.loopStartCompleted = true
                    self?.startInFlight = false
                    if let readyError {
                        elog(.error, "TUNNEL", "packet loop ready error: \(readyError)")
                        self?.lastRuntimeError = "packetLoop: \(readyError.localizedDescription)"
                        self?.cancelTunnelWithError(readyError)
                    } else {
                        elog(.info, "TUNNEL", "packet loop ready OK")
                        self?.tunnelPhase = "ready"
                    }
                    completionHandler(readyError)
                }
                // Watchdog: if the loop never reports back, the app would hang
                // on CONNECTING forever and the system would eventually kill a
                // silent tunnel. Fail loudly instead so the app dump shows why.
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) { [weak self] in
                    guard let self, !self.loopStartCompleted, self.tunnelPhase == "network-settings" else { return }
                    elog(.error, "TUNNEL", "packet loop start TIMEOUT (no ready callback in 15s)")
                    self.lastRuntimeError = "packetLoop start timeout (no ready callback in 15s)"
                    self.cancelTunnelWithError(SSHPacketTunnelError.probeFailed)
                }
            }
        } catch {
            elog(.error, "TUNNEL", "startTunnel THREW: \(error)")
            tunnelPhase = "error"
            startInFlight = false
            lastRuntimeError = error.localizedDescription
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        let text = TunnelStopReason.text(forRawValue: reason.rawValue)
        lastStopReason = text
        startInFlight = false
        elog(.info, "TUNNEL", "stopTunnel reason=\(text) phase=\(tunnelPhase) lastError=\(lastRuntimeError ?? "none")")
        packetLoop?.stop()
        packetLoop = nil
        transport?.stop()
        transport = nil
        completionHandler()
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        packetLoop?.suspend()
        completionHandler()
    }

    override func wake() {
        packetLoop?.resume()
    }

    /// Stable per-install device identity stored in the app group. Reused as
    /// the gateway broker id so reconnects adopt the same TUN instead of
    /// orphaning the previous one.
    private static func persistentDeviceIdentity() -> String {
        let defaults = UserDefaults(suiteName: "group.com.sshtunnel.shared") ?? .standard
        if let existing = defaults.string(forKey: "vpn.device.id"), !existing.isEmpty {
            return existing
        }
        let generated = String(UUID().uuidString.filter { $0 != "-" }.lowercased())
        defaults.set(generated, forKey: "vpn.device.id")
        return generated
    }
}

private struct TunnelConfiguration {
    let host: String
    let port: Int
    let username: String
    let password: String?
    let privateKey: NIOSSHPrivateKey?
    let hostKey: String?
    let dnsServers: [String]

    init(providerConfiguration: [String: Any]?) throws {
        guard let providerConfiguration,
              let host = providerConfiguration["host"] as? String, !host.isEmpty,
              let username = providerConfiguration["username"] as? String, !username.isEmpty
        else { throw SSHPacketTunnelError.invalidConfiguration }
        let port = (providerConfiguration["port"] as? NSNumber)?.intValue ?? 22
        guard (1...65535).contains(port) else { throw SSHPacketTunnelError.invalidConfiguration }
        self.host = host; self.port = port; self.username = username
        // Credentials are embedded directly in the provider configuration by
        // the app (plain local storage in the shared profile), so no Keychain
        // dependency is required here.
        self.password = (providerConfiguration["password"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let rawKey = providerConfiguration["privateKey"] as? String, !rawKey.isEmpty {
            self.privateKey = try SSHPrivateKeyImporter.importEd25519(
                SSHPrivateKeyImporter.canonicalSeed(from: Data(rawKey.utf8))
            )
        } else { self.privateKey = nil }
        // Host key (TOFU hardening) is optional: when absent the transport
        // accepts the first key. Only fail if there is no way to authenticate
        // at all (no password AND no key).
        let rawHostKey = (providerConfiguration["hostKey"] as? String) ?? ""
        let trimmed = rawHostKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.hostKey = trimmed.isEmpty ? nil : trimmed
        if self.password == nil && self.privateKey == nil {
            throw SSHPacketTunnelError.invalidConfiguration
        }
        self.dnsServers = (providerConfiguration["dnsServers"] as? [String]) ?? []
    }
}

/// One transport drives all SSH child sessions and the single packet tunnel.
///
/// Reconnect, heartbeat and backpressure live behind PacketTunnelTransport so
/// the NetworkExtension packetFlow stays the only Apple-owned piece here.
private final class SSHPacketTunnelTransport: PacketTunnelTransport, @unchecked Sendable {
    private let configuration: TunnelConfiguration
    private let endpoint: SSHResolvedEndpoint
    private let bundle: Bundle
    private let stateQueue = DispatchQueue(label: "com.sshtunnel.transport-state")
    private var factory: SSHTransportFactory?

    private var sessionCredentials: SSHCredentials?
    private var sessionCommand: String?
    private var sessions = [SSHTransportSession]()
    private var sessionTokens = [String: SSHTransportSession]()
    private var authenticatedTokens = Set<String>()
    private var heartbeat = HeartbeatTracker()
    private var heartbeatTimer: DispatchSourceTimer?
    private let heartbeatInterval: TimeInterval = 10
    private let heartbeatThreshold = 2

    private var nextSession = 0
    private let desiredSessionCount = 3
    private var reconnectController: GatewayReconnectController
    private var reconnectWorkItem: DispatchWorkItem?
    private var pathMonitor: NWPathMonitor?
    private var stopped = false

    private var receivePacket: ((Data) -> Void)?
    private var failure: ((Error) -> Void)?
    private var ready: ((Error?) -> Void)?
    private var pending = [(packet: Data, completion: (Error?) -> Void)]()
    private let maxPendingPackets = 512
    private var pendingBytes = 0
    private let maxPendingBytes = 256 * 1024

    private let brokerID: String

    init(configuration: TunnelConfiguration, endpoint: SSHResolvedEndpoint, brokerID: String, bundle: Bundle) throws {
        self.configuration = configuration
        self.endpoint = endpoint
        self.brokerID = brokerID
        self.bundle = bundle
        self.reconnectController = GatewayReconnectController(desiredSessionCount: 3)
        self.factory = try SSHTransportFactory(pinnedOpenSSHHostKey: configuration.hostKey)
    }

    func start(receive: @escaping (Data) -> Void, failure: @escaping (Error) -> Void, ready: @escaping (Error?) -> Void) {
        elog(.info, "TRANSPORT", "start() invoked; desired sessions=\(desiredSessionCount)")
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.reset()
            self.receivePacket = receive
            self.failure = failure
            self.ready = ready
            _ = self.reconnectController.stateMachine.start()

            let monitor = NWPathMonitor()
            self.pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.stateQueue.async {
                if path.status == .satisfied {
                    if !self.reconnectController.didReportReady && self.sessions.isEmpty { self.scheduleReconnect() }
                    return
                }
                    // Force failed sockets to emit channelInactive; the normal
                    // reconnect path then recreates child sessions after the
                    // bounded backoff while packet data stays in the bounded
                    // pending queue.
                    self.sessions.forEach { $0.close() }
                }
            }
            monitor.start(queue: DispatchQueue.global(qos: .utility))

            guard let scriptURL = self.bundle.url(forResource: "gateway", withExtension: "py"),
                  let script = try? Data(contentsOf: scriptURL),
                  let factory = self.factory else {
                elog(.error, "TRANSPORT", "gateway.py missing or factory nil -> gatewayMissing")
                self.reconnectController.stateMachine.fail(.protocolViolation)
                ready(SSHPacketTunnelError.gatewayMissing)
                return
            }
            elog(.info, "TRANSPORT", "gateway.py loaded (\(script.count) bytes); opening \(self.desiredSessionCount) SSH sessions")
            let target = self.endpoint.primaryTarget() ?? self.configuration.host
            let credentials = SSHCredentials(
                host: target,
                port: self.configuration.port,
                username: self.configuration.username,
                password: self.configuration.password,
                privateKey: self.configuration.privateKey
            )
            let command = GatewayCommandBuilder.pythonInline(script: script, brokerID: self.brokerID)
            self.sessionCredentials = credentials
            self.sessionCommand = command
            for _ in 0..<self.desiredSessionCount { self.openOne(credentials: credentials, command: command, factory: factory) }
            self.startHeartbeat()
        }
    }

    private func openOne(credentials: SSHCredentials, command: String, factory: SSHTransportFactory) {
        guard !stopped else { return }
        let token = UUID().uuidString
        let nonce = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        let sessionHolder = SessionHolder()
        let handshake = LockedSessionHandshake(nonce: nonce)
        factory.openSession(credentials, command: command, receive: { [weak self] frame in
            self?.stateQueue.async {
                guard let self else { return }
                switch frame.type {
                case .helloAck:
                    elog(.info, "SESSION", "received helloAck (SSH channel authenticated+handshaked)")
                    if (try? handshake.accept(frame)) == nil {
                        sessionHolder.session?.close()
                        self.handleSessionFailure(SSHPacketTunnelError.probeFailed)
                        return
                    }
                    self.authenticatedTokens.insert(token)
                    if let ping = try? TransportFrame(type: .ping) {
                        sessionHolder.session?.send(ping)
                        self.heartbeat.markSent(token)
                    }
                case .pong:
                    NSLog("[SSH2VPN][SESSION] received pong")
                    guard handshake.isAuthenticated else { return }
                    self.heartbeat.markPong(token)
                    self.reconnectController.setSessions(self.sessions.count)
                    self.reconnectController.isStopped = self.stopped
                    if case .reportReady = self.reconnectController.sessionAuthenticated() {
                        self.ready?(nil)
                        self.flush()
                    }
                default:
                    break
                }
                if let packet = try? RawPacketBridge.inboundPacket(from: frame) { self.receivePacket?(packet) }
            }
        }, failure: { [weak self] error in
            self?.stateQueue.async {
                self?.handleSessionFailure(error)
            }
        }).whenComplete { [weak self] result in
            self?.stateQueue.async {
                guard let self else { return }
                switch result {
                case .success(let childSession):
                    elog(.info, "SESSION", "openSession success (SSH connected)")
                    self.sessions.append(childSession)
                    self.sessionTokens[token] = childSession
                    sessionHolder.session = childSession
                    self.reconnectController.incrementSessions()
                    if let hello = try? TransportFrame(type: .hello, payload: nonce) {
                        childSession.send(hello)
                    }
                case .failure(let error):
                    self.reconnectController.setSessions(self.sessions.count)
                    self.reconnectController.isStopped = self.stopped
                    switch self.reconnectController.initialAttemptFailed(isFatal: self.isFatal(error)) {
                    case .failAuthentication:
                        self.failure?(error)
                    case .failTransport:
                        self.ready?(error)
                    case .scheduleReconnect:
                        self.scheduleReconnect()
                    case .reportReady, .noOp:
                        break
                    }
                }
            }
        }
    }

    /// Diagnostic: sessions currently tracked by the transport. Read off-queue
    /// on purpose (same as the loop counters) — informational only.
    var sessionCount: Int { sessions.count }

    func send(packet: Data, completion: @escaping (Error?) -> Void) {
        stateQueue.async { [weak self] in
            guard let self else { completion(SSHPacketTunnelError.cancelled); return }
            guard !self.sessions.isEmpty else {
                // No authenticated session yet: bound the queue by both count
                // and bytes so a stalled handshake cannot grow memory forever.
                guard self.pending.count < self.maxPendingPackets,
                      self.pendingBytes + packet.count <= self.maxPendingBytes
                else { completion(SSHPacketTunnelError.backpressure); return }
                self.pending.append((packet, completion))
                self.pendingBytes += packet.count
                return
            }
            let session = self.sessions[self.nextSession % self.sessions.count]
            self.nextSession += 1
            do { session.send(try RawPacketBridge.outboundFrame(for: packet), completion: completion) }
            catch { completion(error) }
        }
    }

    func stop() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            _ = self.reconnectController.stateMachine.stop()
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            self.pathMonitor?.cancel()
            self.pathMonitor = nil
            self.stopHeartbeat()
            self.sessions.forEach { $0.close() }
            self.sessions.removeAll()
            self.sessionTokens.removeAll()
            self.authenticatedTokens.removeAll()
            self.pending.forEach { $0.completion(SSHPacketTunnelError.cancelled) }
            self.pending.removeAll()
            self.pendingBytes = 0
        }
    }

    private func flush() {
        let packets = pending
        pending.removeAll()
        pendingBytes = 0
        for (packet, completion) in packets { send(packet: packet, completion: completion) }
    }

    private func scheduleReconnect() {
        reconnectController.isStopped = stopped
        guard case .scheduleReconnect = reconnectController.scheduleReconnect() else { return }
        let delay = ReconnectPolicy(baseDelay: 1, maxDelay: 30, jitter: 0.2)
            .delay(for: reconnectController.reconnectAttempt, randomUnit: Double.random(in: 0...1))
        let work = DispatchWorkItem { [weak self] in
            self?.stateQueue.async {
                guard let self, !self.stopped else { return }
                self.reconnectWorkItem = nil
                self.reconnectController.reconnectFired()
                if let credentials = self.sessionCredentials,
                   let command = self.sessionCommand,
                   let factory = self.factory {
                    self.openOne(credentials: credentials, command: command, factory: factory)
                }
            }
        }
        reconnectWorkItem = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func reset() {
        stopped = false
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        stopHeartbeat()
        sessions.forEach { $0.close() }
        sessions.removeAll()
        sessionTokens.removeAll()
        authenticatedTokens.removeAll()
        heartbeat.reset()
        pending.forEach { $0.completion(SSHPacketTunnelError.cancelled) }
        pending.removeAll()
        pendingBytes = 0
        nextSession = 0
        reconnectController = GatewayReconnectController(desiredSessionCount: desiredSessionCount)
    }

    private func handleSessionFailure(_ error: Error) {
        elog(.error, "SESSION", "failure: \(error)")
        sessions.removeAll { !$0.isActive }
        discardDeadTokens()
        reconnectController.setSessions(sessions.count)
        reconnectController.isStopped = stopped
        // Post-ready every loss is topped back up to the session count; pre
        // ready, only schedule when nothing is left to avoid stacking new
        // connects while the remaining sessions are still opening.
        if case .scheduleReconnect = reconnectController.sessionLost() {
            scheduleReconnect()
        }
        _ = error
    }

    private func discardDeadTokens() {
        for (token, session) in sessionTokens where !session.isActive {
            authenticatedTokens.remove(token)
            heartbeat.remove(token)
        }
        sessionTokens = sessionTokens.filter { $0.value.isActive }
    }

    private func isFatal(_ error: Error) -> Bool {
        error is SSHTransportError
    }

    private func startHeartbeat() {
        stopHeartbeat()
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + heartbeatInterval, repeating: heartbeatInterval)
        timer.setEventHandler { [weak self] in self?.heartbeatTick() }
        timer.resume()
        heartbeatTimer = timer
    }

    private func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    private func heartbeatTick() {
        guard !stopped else { return }
        let now = Date()
        for (token, session) in sessionTokens where authenticatedTokens.contains(token) {
            if let ping = try? TransportFrame(type: .ping) { session.send(ping) }
            heartbeat.markSent(token, at: now)
        }
        for token in heartbeat.deadTokens(at: now, interval: heartbeatInterval, threshold: heartbeatThreshold) {
            // Silent sessions are torn down; their channelInactive triggers the
            // normal reconnect path instead of leaving a blackhole behind.
            authenticatedTokens.remove(token)
            heartbeat.remove(token)
            sessionTokens[token]?.close()
        }
    }
}

private enum SSHPacketTunnelError: Error {
    case invalidConfiguration
    case gatewayMissing
    case transportLost
    case protocolViolation
    case probeFailed
    case keychainUnavailable
    case backpressure
    case cancelled
}

extension SSHPacketTunnelError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "The tunnel configuration is invalid. Check host, port and credentials."
        case .gatewayMissing:
            return "No network gateway was found on this server."
        case .transportLost:
            return "The SSH transport was lost."
        case .protocolViolation:
            return "The server returned an unexpected protocol response."
        case .probeFailed:
            return "The connection probe timed out."
        case .keychainUnavailable:
            return "Stored credentials could not be read."
        case .backpressure:
            return "The tunnel is overloaded."
        case .cancelled:
            return "The connection was cancelled."
        }
    }
}

private final class LockedSessionHandshake: @unchecked Sendable {
    private var value: SessionHandshake
    private let lock = NSLock()

    init(nonce: Data) { value = SessionHandshake(nonce: nonce) }

    func accept(_ frame: TransportFrame) throws {
        lock.lock()
        defer { lock.unlock() }
        _ = try value.accept(frame)
    }

    var isAuthenticated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value.state == .authenticated
    }
}

private final class SessionHolder: @unchecked Sendable {
    var session: SSHTransportSession?
}

