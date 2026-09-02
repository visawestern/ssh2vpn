import Foundation
import Network
import NetworkExtension
import VPNCore

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var packetLoop: PacketTunnelPacketLoop?
    private var transport: SSHPacketTunnelTransport?

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        do {
            let providerConfiguration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
            let configuration = try TunnelConfiguration(providerConfiguration: providerConfiguration)
            // Resolve once and pin the whole tunnel to that result: the route
            // exclusions below must match the address the SSH socket actually
            // connects to, otherwise the tunnel can recursively carry it.
            let endpoint = try SSHEndpointResolver.resolve(configuration.host)
            // The device identity is persisted so a reconnect (and the gateway
            // broker socket) stays stable across tunnel restarts, while being
            // unique per install so two phones sharing one VPS never collide.
            let brokerID = Self.persistentDeviceIdentity()
            let device = try TunnelDevice.derive(brokerID: brokerID)
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

            let transport = try SSHPacketTunnelTransport(configuration: configuration, endpoint: endpoint, brokerID: brokerID, bundle: .main)
            self.transport = transport
            setTunnelNetworkSettings(settings) { [weak self] error in
                guard let self, error == nil else { completionHandler(error); return }
                let loop = PacketTunnelPacketLoop(packetFlow: self.packetFlow, transport: transport)
                self.packetLoop = loop
                loop.start { [weak self] readyError in
                    if let readyError {
                        self?.cancelTunnelWithError(readyError)
                    }
                    completionHandler(readyError)
                }
            }
        } catch {
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
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
    let hostKey: String
    let dnsServers: [String]

    init(providerConfiguration: [String: Any]?) throws {
        guard let providerConfiguration,
              let host = providerConfiguration["host"] as? String, !host.isEmpty,
              let username = providerConfiguration["username"] as? String, !username.isEmpty,
              let hostKey = providerConfiguration["hostKey"] as? String, !hostKey.isEmpty
        else { throw SSHPacketTunnelError.invalidConfiguration }
        let port = (providerConfiguration["port"] as? NSNumber)?.intValue ?? 22
        guard (1...65535).contains(port) else { throw SSHPacketTunnelError.invalidConfiguration }
        self.host = host; self.port = port; self.username = username
        // A key reference in the config implies the credential must be in the
        // keychain; a missing or unreadable entry fails loudly instead of
        // silently downgrading to an unauthenticated session.
        if let passwordKey = providerConfiguration["passwordKey"] as? String {
            guard let stored = try? KeychainStore.read(account: passwordKey) else {
                throw SSHPacketTunnelError.keychainUnavailable
            }
            self.password = stored
        } else { self.password = nil }
        if let privateKeyKey = providerConfiguration["privateKeyKey"] as? String {
            guard let encoded = try? KeychainStore.read(account: privateKeyKey),
                  let seed = Data(base64Encoded: encoded) else {
                throw SSHPacketTunnelError.keychainUnavailable
            }
            self.privateKey = try SSHPrivateKeyImporter.importEd25519(seed)
        } else { self.privateKey = nil }
        self.hostKey = hostKey
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
                self.reconnectController.stateMachine.fail(.protocolViolation)
                ready(SSHPacketTunnelError.gatewayMissing)
                return
            }
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