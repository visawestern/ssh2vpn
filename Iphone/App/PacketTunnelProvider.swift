import Foundation
import Network
import NetworkExtension
import NIOCore
import NIOSSH
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
    private var transport: PacketTunnelTransport?
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
    /// Cancel handshake between stopTunnel and the async start sequence:
    /// stopTunnel during an in-flight start sets the flag and parks its
    /// completion; the start unwinds at the next cancel checkpoint and only
    /// THEN fires the parked stop completion. Serializes the trio.
    private let stopLock = NSLock()
    private var startCancelled = false
    private var pendingStopCompletion: (() -> Void)?

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
                let lastReadAgo: String
                if let at = self?.packetLoop?.lastReadAt {
                    lastReadAgo = "\(max(0, Int(Date().timeIntervalSince(at))))s"
                } else {
                    lastReadAgo = "never"
                }
                return ["phase": self?.tunnelPhase ?? "idle",
                 "transport": self?.transport == nil ? "nil" : "set",
                 "stopReason": self?.lastStopReason ?? "none",
                 "packetsRead": "\(self?.packetLoop?.packetsRead ?? 0)",
                 "packetsWritten": "\(self?.packetLoop?.packetsWritten ?? 0)",
                 "replied": "\((self?.transport as? RelayTransport)?.repliedCount() ?? 0)",
                 "sessions": "\((self?.transport as? RelayTransport)?.flowCount() ?? 0)",
                 "sshConns": "\((self?.transport as? RelayTransport)?.sshConnectionCount() ?? 0)",
                 "channels": "\((self?.transport as? RelayTransport)?.activeChannelCount() ?? 0)",
                 "upBytes": "\((self?.transport as? RelayTransport)?.byteTotals().up ?? 0)",
                 "downBytes": "\((self?.transport as? RelayTransport)?.byteTotals().down ?? 0)",
                 "proto": self?.packetLoop?.protoSummary ?? "none",
                 "lastReadAgo": lastReadAgo]
            },
            errorProvider: { [weak self] in
                ["error": self?.lastRuntimeError ?? "none"]
            },
            logProvider: { ConsoleLogStore.shared.entries }
        )
        completionHandler?(router.handle(messageData))
    }

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        elog(.info, "TUNNEL", "startTunnel BEGIN (relay mode — no root/TUN needed on server)")
        stopLock.lock()
        if startInFlight {
            stopLock.unlock()
            elog(.warning, "TUNNEL", "startTunnel RE-ENTERED while a start is already in flight")
            lastRuntimeError = "startTunnel re-entered while previous start in flight"
        }
        startInFlight = true
        startCancelled = false
        stopLock.unlock()
        // CRITICAL: never block THIS thread. It used to run the SSH connect
        // and the forwarding probe inline (connect().wait() + a semaphore),
        // so a stopTunnel delivered mid-start had to queue behind up to ~15s
        // of blocking work — the "VPN hangs when cancelled" flake. The whole
        // start sequence now runs on a background queue; stopTunnel cancels
        // it at the checkpoints inside runStartSequence.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.runStartSequence(completionHandler: completionHandler)
        }
    }

    private func runStartSequence(completionHandler: @escaping (Error?) -> Void) {
        tunnelPhase = "begin"
        do {
            var providerConfiguration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
            elog(.info, "TUNNEL", "providerConfiguration keys: \(providerConfiguration?.keys.sorted() ?? [])")
            // Extension-owned server list is the source of truth for the
            // SERVER (host/credentials), but NOT for per-connection settings:
            // dnsServers / dnsRules are freshly chosen by the user on every
            // connect and arrive in providerConfiguration. The store's copy
            // stays stale (last-saved profile) — overwriting the fresh values
            // with it is the "selected a preset but the tunnel still runs the
            // old 8.8.8.8" bug.
            if let selectedID = serverStore.selectedID(),
               let selected = serverStore.load(id: selectedID) {
                var merged = providerConfiguration ?? [:]
                merged["host"] = selected.host
                merged["port"] = selected.port
                merged["username"] = selected.username
                merged["hostKey"] = selected.hostKey
                if let pwd = selected.password, !pwd.isEmpty { merged["password"] = pwd }
                else { merged.removeValue(forKey: "password") }
                if let key = selected.privateKey, !key.isEmpty { merged["privateKey"] = key }
                else { merged.removeValue(forKey: "privateKey") }
                // Keep the app-provided DNS when present; fall back to the
                // stored profile only when the app sent nothing (first start,
                // on-demand launch without the app).
                let appDNS = (providerConfiguration?["dnsServers"] as? [String]) ?? []
                merged["dnsServers"] = appDNS.isEmpty ? selected.dnsServers : appDNS
                providerConfiguration = merged
                elog(.info, "TUNNEL", "using extension-owned server id=\(selectedID) host=\(selected.host) dns=\(merged["dnsServers"] ?? [])")
            }
            let configuration = try TunnelConfiguration(providerConfiguration: providerConfiguration)
            tunnelPhase = "config"
            elog(.info, "TUNNEL", "TunnelConfiguration OK host=\(configuration.host) port=\(configuration.port) user=\(configuration.username)")
            // Persist effective config into the extension-owned store.
            if serverStore.needsDedupe() {
                serverStore.markDeduped()
                let dupes = ServerDedupe.duplicateIDs(servers: serverStore.loadAll(), selectedID: serverStore.selectedID())
                for id in dupes { serverStore.delete(id: id) }
            }
            let persistID: String = {
                if let sel = serverStore.selectedID(), serverStore.load(id: sel) != nil { return sel }
                if let match = ServerDedupe.matchID(servers: serverStore.loadAll(), host: configuration.host, port: configuration.port, username: configuration.username) { return match }
                return UUID().uuidString
            }()
            var storedProfile = serverStore.load(id: persistID) ?? ServerProfile(
                id: persistID, name: configuration.host, host: configuration.host, port: configuration.port,
                username: configuration.username, hostKey: configuration.hostKey ?? "",
                dnsServers: configuration.dnsServers, hasPassword: false, hasPrivateKey: false)
            // Keep the store's DNS in step with what the app just sent, so
            // the next on-demand start (no app involved) uses the same choice.
            if !configuration.dnsServers.isEmpty {
                storedProfile.dnsServers = configuration.dnsServers
            }
            storedProfile.password = configuration.password
            storedProfile.privateKey = (providerConfiguration?["privateKey"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            storedProfile.hasPassword = storedProfile.password?.isEmpty == false
            storedProfile.hasPrivateKey = storedProfile.privateKey?.isEmpty == false
            serverStore.save(storedProfile)
            serverStore.select(id: persistID)

            // UNUSED (TUN mode removed — no root on server): endpoint resolution,
            // TunnelDevice.derive, NEPacketTunnelNetworkSettings with routes.
            // These are kept as commented reference but are not invoked.
            // let endpoint = try SSHEndpointResolver.resolve(configuration.host)
            // let device = try TunnelDevice.derive(brokerID: Self.persistentDeviceIdentity())
            // ... (see git history for full TUN network settings)

            // Relay mode: connect SSH, then parse/relay TCP over direct-tcpip channels.
            tunnelPhase = "ssh-connect"
            let factory = try SSHTransportFactory(pinnedOpenSSHHostKey: configuration.hostKey)
            let credentials = SSHCredentials(host: configuration.host, port: configuration.port,
                                            username: configuration.username,
                                            password: configuration.password, privateKey: nil)
            let sshChannel = try factory.connect(credentials).wait()
            let sshHandler = try sshChannel.pipeline.handler(type: NIOSSHHandler.self).wait()
            tunnelPhase = "ssh-connected"
            // Cancel checkpoint #1: the user hit disconnect while we were
            // blocking on the SSH connect. Close the parent channel and get
            // out — never install half a tunnel.
            if abandonStartIfCancelled(completionHandler, stage: "post-ssh-connect") {
                sshChannel.close(promise: nil)
                return
            }
            elog(.info, "TUNNEL", "SSH connected; probing TCP forwarding (direct-tcpip)")
            // Pre-flight probe: one throwaway direct-tcpip open proves auth is
            // done AND the server forwards. Without it, later fire-and-forget
            // opens can hang forever on a stuck auth or AllowTcpForwarding=no,
            // leaving a blackholed tunnel with zero diagnostics.
            var probeError: Error?
            for target in [("8.8.8.8", 53), ("1.1.1.1", 53)] {
                do {
                    try SSHChannelProbe.probe(handler: sshHandler, eventLoop: sshChannel.eventLoop,
                                              host: target.0, port: target.1, timeoutSeconds: 5)
                    elog(.info, "TUNNEL", "forwarding probe OK via \(target.0):\(target.1)")
                    probeError = nil
                    break
                } catch {
                    elog(.warning, "TUNNEL", "forwarding probe via \(target.0):\(target.1) failed: \(error.localizedDescription)")
                    probeError = error
                }
            }
            if let probeError {
                let msg: String
                switch probeError {
                case SSHProbeError.timeout(let h, let p, let s):
                    msg = "SSH forwarding probe timed out (\(h):\(p), \(s)s) — auth stuck or server silent"
                case SSHProbeError.refused(let h, let p, let detail):
                    msg = "SSH forwarding refused (\(h):\(p)): \(detail) — check password and AllowTcpForwarding on server"
                default:
                    msg = "SSH forwarding probe failed: \(probeError.localizedDescription)"
                }
                elog(.error, "TUNNEL", msg)
                tunnelPhase = "probe-failed"
                lastRuntimeError = msg
                TunnelLastError.write(msg)
                completeStart(probeError, completionHandler: completionHandler)
                return
            }
            // Cancel checkpoint #2: probe round is over, the tunnel is not
            // installed yet — bailing now leaves no utun/route cleanup debt.
            if abandonStartIfCancelled(completionHandler, stage: "post-probe") {
                sshChannel.close(promise: nil)
                return
            }
            elog(.info, "TUNNEL", "SSH connected; starting relay transport")

            // Parallel SSH pool: starts with the one already-authenticated
            // connection, grows on demand (all channels saturated) up to the
            // policy max, and logs every step under the POOL tag.
            let connector: SSHConnectionPool.Connector = { completion in
                factory.connect(credentials)
                    .flatMap { ch in
                        ch.pipeline.handler(type: NIOSSHHandler.self)
                            .map { SSHConnectionPool.Link(channel: ch, handler: $0) }
                    }
                    .whenComplete { completion($0) }
            }
            let pool = SSHConnectionPool(initial: SSHConnectionPool.Link(channel: sshChannel, handler: sshHandler),
                                         connector: connector)
            elog(.info, "POOL", "ssh pool ready: 1 connection (grows on demand, max 4)")

            let dnsUpstream = configuration.dnsServers.first(where: { !$0.isEmpty }) ?? "8.8.8.8"
            let relay = RelayTransport(factory: factory,
                                       pool: pool,
                                       dnsServers: configuration.dnsServers,
                                       dnsRules: configuration.dnsRules,
                                       receive: { [weak self] packet in
                                           guard let self else { return }
                                           let proto = packet.first.map { ($0 >> 4) == 6 ? AF_INET6 : AF_INET } ?? AF_INET
                                           self.packetFlow.writePackets([packet], withProtocols: [NSNumber(value: proto)])
                                       },
                                       failure: { [weak self] error in
                                           let msg = "relay: \(error.localizedDescription)"
                                           self?.lastRuntimeError = msg
                                           TunnelLastError.write(msg)
                                           self?.cancelTunnelWithError(error)
                                       },
                                       ready: { _ in })
            self.transport = relay
            tunnelPhase = "transport"
            elog(.info, "TUNNEL", "relay transport ready; calling setTunnelNetworkSettings")

            // Minimal network settings: route all IPv4/IPv6 to utun. The relay
            // handles per-flow routing itself. Addresses MUST be unique per install
            // (TunnelDevice-derived): a hardcoded 10.0.0.2 collides with common LAN
            // subnets (10.0.0.0/24) and silently blackholes all traffic.
            // IMPORTANT: mask /24 (not /30) so iOS installs the default route.
            // Exclude the VPN server IP so the SSH transport doesn't route through itself.
            let brokerID = Self.persistentDeviceIdentity()
            let device = try TunnelDevice.derive(brokerID: brokerID)
            // Subnet occupancy (silent to the user, loud in logs): if our /24
            // sits inside a live local network, iOS drops the v4 settings
            // without a word and all IPv4 bypasses the tunnel. Take the
            // stable primary when free, otherwise the first free fallback.
            let occupied = LocalInterfaceNets.listIPv4Networks()
            let choice = TunnelSubnetPicker.pick(brokerID: brokerID, occupied: occupied)
            let occDesc = occupied.map(\.description).joined(separator: ",")
            elog(.info, "TUNNEL", "subnet check occupied=[\(occDesc.isEmpty ? "none" : occDesc)] -> \(choice.net) device=\(choice.deviceAddress)\(choice.collided ? " ALL-COLLIDED(using primary anyway)" : "")")
            elog(.info, "TUNNEL", "device derived ipv4=\(choice.deviceAddress) ipv6=\(device.ipv6Address)")
            let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: configuration.host)
            settings.ipv4Settings = NEIPv4Settings(addresses: [choice.deviceAddress], subnetMasks: [TunnelDevice.v4SubnetMask])
            settings.ipv4Settings?.includedRoutes = [NEIPv4Route.default()]
            // NOTE: no manual excludedRoutes for the server IP. iOS already
            // excludes tunnelRemoteAddress from the tunnel automatically; our
            // explicit exclusion duplicated it and (evidence across dumps:
            // IPv6 gateway present, IPv4 gateway missing, v4 dead after T+0)
            // appears to break the v4-gateway synthesis, silently dropping
            // the v4 default while setTunnelNetworkSettings still returns OK.
            // SSH stays loop-free via the automatic exclusion (as in all
            // pre-2300 builds). serverIP stays in providerConfiguration
            // (harmless, keeps the reuse-path snapshot stable).
            // EXPERIMENT (v4-only): the dual-stack utun (real v4 + synthetic
            // fd00 ULA) correlates with a missing IPv4 gateway — NWPath shows
            // an IPv6-only gateway, v6 packets arrive, v4 TCP gets ENETDOWN
            // from the kernel. Hypothesis: the artificial ULA poisons v4
            // gateway synthesis. Relay is v4-only anyway, so drop v6 settings
            // and force iOS to deal with a pure v4 tunnel. Reversible.
            settings.ipv6Settings = nil
            // Settings echo: proves WHAT we installed (vs what iOS honored —
            // compare with the NWPath gateways line in the self-test).
            elog(.info, "TUNNEL", "netsettings v4=\(choice.deviceAddress)/24 default excluded=0 v6=none(v4-only-experiment) dns=\(dnsUpstream)")
            if !configuration.dnsServers.isEmpty {
                let dns = NEDNSSettings(servers: configuration.dnsServers)
                dns.matchDomains = [""]
                settings.dnsSettings = dns
            } else {
                // Always pin DNS to the relay's upstream: without dnsSettings
                // the phone keeps querying the physical LAN resolver, whose
                // address is unreachable from the VPS (LAN blackhole) — DNS
                // dies and URLSession reports "offline". matchDomains [""] sends
                // every lookup through utun into the DNS-over-TCP relay.
                let dns = NEDNSSettings(servers: [dnsUpstream])
                dns.matchDomains = [""]
                settings.dnsSettings = dns
            }

            // Route-debug: dump the ACTUAL installed objects (not our intent).
            // If includedRoutes ever shows NONE here, the default route was
            // never even handed to iOS.
            if let v4 = settings.ipv4Settings {
                let inc = (v4.includedRoutes ?? []).map { "\($0.destinationAddress)/\($0.destinationSubnetMask)" }.joined(separator: ",")
                let exc = (v4.excludedRoutes ?? []).map { "\($0.destinationAddress)/\($0.destinationSubnetMask)" }.joined(separator: ",")
                elog(.info, "TUNNEL", "routes v4 addr=\(v4.addresses) mask=\(v4.subnetMasks) included=[\(inc.isEmpty ? "NONE" : inc)] excluded=[\(exc.isEmpty ? "none" : exc)]")
            } else {
                elog(.error, "TUNNEL", "routes v4Settings is NIL!")
            }

            setTunnelNetworkSettings(settings) { [weak self] error in
                guard let self else { return }
                if let error {
                    elog(.error, "TUNNEL", "setTunnelNetworkSettings FAILED: \(error)")
                    self.lastRuntimeError = "setTunnelNetworkSettings: \(error.localizedDescription)"
                    TunnelLastError.write(self.lastRuntimeError ?? "setTunnelNetworkSettings failed")
                    self.completeStart(error, completionHandler: completionHandler)
                    return
                }
                self.tunnelPhase = "network-settings"
                elog(.info, "TUNNEL", "setTunnelNetworkSettings OK")
                let loop = PacketTunnelPacketLoop(packetFlow: self.packetFlow, transport: relay)
                self.packetLoop = loop
                self.loopStartCompleted = false
                loop.start { [weak self] readyError in
                    self?.loopStartCompleted = true
                    if let readyError {
                        elog(.error, "TUNNEL", "packet loop ready error: \(readyError)")
                        self?.lastRuntimeError = "packetLoop: \(readyError.localizedDescription)"
                        TunnelLastError.write(self?.lastRuntimeError ?? "packetLoop failed")
                        self?.cancelTunnelWithError(readyError)
                    } else {
                        elog(.info, "TUNNEL", "packet loop ready OK")
                        self?.tunnelPhase = "ready"
                        // Tunnel survived startup — any stale persisted failure
                        // from an earlier death is now obsolete.
                        TunnelLastError.clear()
                    }
                    self?.completeStart(readyError, completionHandler: completionHandler)
                }
            }
        } catch {
            elog(.error, "TUNNEL", "startTunnel THREW: \(error)")
            tunnelPhase = "error"
            lastRuntimeError = error.localizedDescription
            // Persist: the process may be torn down within milliseconds and
            // the message channel dies with it — without this the app sees
            // extError=none and retries blindly into a fail2ban lockout.
            TunnelLastError.write(error.localizedDescription)
            completeStart(error, completionHandler: completionHandler)
        }
    }

    // MARK: - Start/stop coordination

    /// Single exit point for the start sequence: clears the in-flight flag,
    /// fires the start completion, and — if stopTunnel arrived while the
    /// start was mid-flight — fires the parked stop completion right after.
    /// Ordering guarantee: the system never sees stop-completed before
    /// start-completed, which is exactly what the old blocking start broke.
    private func completeStart(_ errorParam: Error?, completionHandler: @escaping (Error?) -> Void) {
        var error = errorParam
        stopLock.lock()
        startInFlight = false
        let pendingStop = pendingStopCompletion
        pendingStopCompletion = nil
        startCancelled = false
        stopLock.unlock()
        // If the cancel landed late (loop already started), a live tunnel is
        // running — tear it down before telling the system the stop is done,
        // otherwise it stays up with NetworkExtension believing it stopped.
        if pendingStop != nil {
            // CRITICAL: report the start as CANCELLED, not as success. With
            // success, NetworkExtension believes the tunnel is up and keeps
            // the routes/DNS binding it installed — then our own teardown runs
            // underneath, leaving iOS holding default routes into a dead utun.
            // On-device that is exactly the "Wi-Fi connected, no internet"
            // zombie state that only a profile removal (or Wi-Fi toggle) heals.
            error = error ?? NSError(domain: "com.ssh2vpn", code: 20,
                                     userInfo: [NSLocalizedDescriptionKey: "connection start cancelled by user"])
            packetLoop?.stop()
            packetLoop = nil
            transport?.stop()
            transport = nil
        }
        completionHandler(error)
        if let pendingStop {
            elog(.info, "TUNNEL", "start unwound after cancel — completing the queued stop now")
            pendingStop()
        }
    }

    /// True when the start was cancelled (also finishes the start if so):
    /// the caller closes whatever SSH channel it holds and returns.
    private func abandonStartIfCancelled(_ completionHandler: @escaping (Error?) -> Void, stage: String) -> Bool {
        stopLock.lock()
        let cancelled = startCancelled
        stopLock.unlock()
        guard cancelled else { return false }
        elog(.info, "TUNNEL", "start CANCELLED at \(stage) — unwinding cleanly, tunnel never installed")
        tunnelPhase = "cancelled"
        let err = NSError(domain: "com.ssh2vpn", code: 20,
                          userInfo: [NSLocalizedDescriptionKey: "connection start cancelled by user"])
        completeStart(err, completionHandler: completionHandler)
        return true
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        let text = TunnelStopReason.text(forRawValue: reason.rawValue)
        lastStopReason = text
        stopLock.lock()
        if startInFlight {
            // A start is blocked in SSH connect/probe on its background
            // queue; stopping the loop now would not reach it. Flag the
            // cancel and park OUR completion — completeStart fires it as
            // soon as the start sequence has fully unwound. This is what
            // makes mid-connect cancels instant instead of "wedged".
            startCancelled = true
            pendingStopCompletion = completionHandler
            stopLock.unlock()
            elog(.info, "TUNNEL", "stopTunnel reason=\(text) mid-start — cancelling in-flight start (phase=\(tunnelPhase))")
            return
        }
        startInFlight = false
        stopLock.unlock()
        elog(.info, "TUNNEL", "stopTunnel reason=\(text) phase=\(tunnelPhase) lastError=\(lastRuntimeError ?? "none")")
        packetLoop?.stop()
        packetLoop = nil
        transport?.stop()
        transport = nil
        completionHandler()
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        // NOTE: deliberately NOT suspending packet reads here. suspend() halts
        // readPackets re-arming, and a missed/late wake() (observed in the
        // wild) then leaves the tunnel "connected" with zero utun traffic
        // forever — the exact delta=0 self-test signature. Background
        // forwarding must continue while the device sleeps; iOS manages power
        // itself. The sleep/wake lines stay so the next dump proves whether
        // device sleep correlates with a stall.
        elog(.info, "TUNNEL", "device sleep (reads continue)")
        completionHandler()
    }

    override func wake() {
        elog(.info, "TUNNEL", "device wake (reads continue)")
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
    let serverIP: String?
    let dnsRules: [DNSBlocklistEntry]

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
        // Pre-resolved server IPv4 from app (avoids blocking DNS in startTunnel).
        self.serverIP = providerConfiguration["serverIP"] as? String
        // Local DNS rules (block -> 0.0.0.0, override -> custom IP) from app
        // settings; JSON-encoded by DNSBlocklistEntry.encodeList.
        self.dnsRules = (providerConfiguration["dnsRules"] as? String).flatMap(DNSBlocklistEntry.decodeList(from:)) ?? []
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
    /// Set once the first session authenticates; the remaining sessions are
    /// then opened staggered instead of as a parallel auth burst (which trips
    /// sshd MaxStartups / fail2ban-style rate limits). Reset on start().
    private var didScaleUp = false
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
            elog(.info, "TRANSPORT", "gateway.py loaded (\(script.count) bytes); opening initial SSH session (1 of \(self.desiredSessionCount), rest scale up staggered after first auth)")
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
            self.openOne(credentials: credentials, command: command, factory: factory)
            self.startHeartbeat()
        }
    }

    /// Opens the remaining sessions staggered once the first one proves the
    /// path and credentials work. Never fires a parallel auth burst against
    /// the server. Runs on stateQueue (all call sites already do).
    private func scaleUpIfNeeded(credentials: SSHCredentials, command: String, factory: SSHTransportFactory) {
        guard !didScaleUp, !stopped else { return }
        didScaleUp = true
        let remaining = max(0, desiredSessionCount - 1)
        guard remaining > 0 else { return }
        elog(.info, "TRANSPORT", "first session authenticated; scaling up \(remaining) more session(s) staggered")
        for i in 0..<remaining {
            stateQueue.asyncAfter(deadline: .now() + 0.7 * Double(i + 1)) { [weak self] in
                guard let self, !self.stopped else { return }
                self.openOne(credentials: credentials, command: command, factory: factory)
            }
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
                    self.scaleUpIfNeeded(credentials: credentials, command: command, factory: factory)
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
        didScaleUp = false
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

// MARK: - Unprivileged TCP relay transport

/// Unprivileged relay transport: instead of shipping raw IP packets to a
/// gateway that needs a TUN device (root), this parses TCP from utun itself
/// and relays each flow through an SSH direct-tcpip channel. No root, no TUN,
/// no iptables needed on the server — just a regular SSH connection.
///
/// Wire format seen by the relay:
///   utun -> IP packet -> parse TCP -> state machine -> direct-tcpip channel -> server -> internet
///   internet -> server -> direct-tcpip channel -> state machine -> IP packet -> utun
final class RelayTransport: PacketTunnelTransport, @unchecked Sendable {
    private var stateMachine: TCPRelayStateMachine
    private let receiveCallback: (Data) -> Void
    private var isStarted = false
    /// Serializes ALL relay-state access (utun send path, SSH callbacks,
    /// sweep timer). NIO callbacks arrive on event loops, utun reads on the
    /// packet thread — without this the structs race.
    private let relayQueue = DispatchQueue(label: "com.ssh2vpn.relay")
    /// Parallel SSH connections to the server; every new flow/DNS query opens
    /// its direct-tcpip channel on the least-loaded one. The pool grows on
    /// demand (see SSHPoolPolicy) and logs every grow event (POOL tag).
    private let pool: SSHConnectionPool
    /// Retains the SSH factory (and its event loop group) for the tunnel's
    /// lifetime. Without this the factory deallocs when startTunnel returns,
    /// its deinit shuts the group down, and every later channel open hangs
    /// forever with no error — the exact silence seen on device. (The old TUN
    /// transport kept its own factory property, which is why it never hit this.)
    private let sshFactory: SSHTransportFactory
    /// Upstream DNS for port-53 relay (profile override or public fallback).
    private let dnsUpstream: String
    /// Open per-query upstream DNS channels (bounded; oldest closed past cap).
    private var dnsInFlight: [AnyObject] = []
    private let maxDNSInFlight = 32
    private var sweepTimer: DispatchSourceTimer?
    /// Local hosts/uBlock-style blocklist — answered with REFUSED before any
    /// upstream query is sent. All access on relayQueue.
    private var localFilter: LocalDNSFilter
    /// Local TTL-capped response cache — repeat lookups never leave the
    /// tunnel. All access on relayQueue.
    private var dnsCache = DNSCache()
    private var dnsCacheHits = 0
    private var dnsBlockedCount = 0
    /// SSH/NAT keepalive: one throwaway direct-tcpip open every 15s. Idle
    /// NAT mappings on flaky Wi-Fi kill the SSH TCP stream after ~45s
    /// otherwise; a tiny SSH round trip keeps every pooled connection
    /// visibly active without any private NIOSSH API.
    private var keepaliveTimer: DispatchSourceTimer?

    /// pending packets received before SSH connected (bounded)
    private var pendingPackets: [Data] = []
    private let maxPending = 64
    /// Flows already logged (one line per flow, no per-packet spam).
    private var loggedFlows = Set<RelayFlow>()
    /// Reply packets emitted toward utun (the loop's own `written` counter
    /// only sees its closure path, so this is the honest number).
    private var repliesWritten = 0

    init(factory: SSHTransportFactory,
         pool: SSHConnectionPool,
         dnsServers: [String] = [],
         dnsRules: [DNSBlocklistEntry] = [],
         receive: @escaping (Data) -> Void,
         failure: @escaping (Error) -> Void,
         ready: @escaping (Error?) -> Void) {
        self.receiveCallback = receive
        self.sshFactory = factory
        self.pool = pool
        self.dnsUpstream = dnsServers.first(where: { !$0.isEmpty }) ?? "8.8.8.8"
        // Local filtering (uBlock/hosts-style): blocked domains answer
        // A 0.0.0.0 and overrides answer the chosen IP — LOCALLY, so no
        // upstream query ever leaves the tunnel. Instant and private.
        self.localFilter = LocalDNSFilter(entries: dnsRules)
        if !localFilter.isEmpty {
            elog(.success, "DNSFILTER", "local rules active: \(localFilter.exactBlocks.count + localFilter.subtreeBlocks.count) block(s), \(localFilter.exactOverrides.count + localFilter.subtreeOverrides.count) override(s) — answered locally before any upstream query")
        }

        self.stateMachine = TCPRelayStateMachine(factory: pool, isnGenerator: RandomISN(), idleTimeout: 120)
        // Server-to-phone splice: channel callbacks arrive on NIO threads and
        // hop onto the relay queue, where they mutate the same state machine
        // the utun send path uses. Replies go straight back into utun.
        self.stateMachine.onChannelData = { [weak self] flow, data in
            guard let self else { return }
            self.relayQueue.async { [weak self] in
                guard let self else { return }
                for reply in self.stateMachine.channelData(data, for: flow) {
                    self.receiveCallback(Data(reply))
                }
            }
        }
        self.stateMachine.onChannelClose = { [weak self] flow in
            guard let self else { return }
            self.relayQueue.async { [weak self] in
                guard let self else { return }
                let before = self.stateMachine.flowStats().first { $0.flow == flow }
                let totals = before.map { "up=\($0.upBytes)B down=\($0.downBytes)B" } ?? "no stats"
                let s = flow.srcAddr.map(String.init).joined(separator: ".")
                let d = flow.dstAddr.map(String.init).joined(separator: ".")
                elog(.info, "RELAY", "flow \(s):\(flow.srcPort) -> \(d):\(flow.dstPort) server closed (\(totals)); FIN to phone")
                for reply in self.stateMachine.channelClosed(flow: flow) {
                    self.receiveCallback(Data(reply))
                }
            }
        }
        elog(.info, "RELAY", "transport created; DNS upstream \(self.dnsUpstream)")
    }

    /// Live flow census for status reporting. Called off-queue like the loop
    /// counters — informational only.
    func flowCount() -> Int { stateMachine.flowCount }

    /// Reply packets emitted toward utun (all paths). Read off-queue like the
    /// other counters — informational only.
    func repliedCount() -> Int { repliesWritten }

    /// Live numbers for the app's stats strip. Read off-queue like the other
    /// counters (a few ms of staleness is fine for a UI readout).
    func sshConnectionCount() -> Int { pool.connectionCount }
    func activeChannelCount() -> Int { pool.snapshotInFlight().reduce(0, +) }
    func byteTotals() -> (up: Int, down: Int) { (stateMachine.totalUpBytes, stateMachine.totalDownBytes) }
    /// Dropped-packet ledger for the 30s journal (reset each sweep): QUIC and
    /// other non-DNS UDP would spam per-packet, so they aggregate here.
    private var droppedUDPNonDNS = 0
    private var droppedNonTCPUDP = 0
    private var droppedParse = 0
    private var lastDroppedDst = "none"

    func start(receive: @escaping (Data) -> Void, failure: @escaping (Error) -> Void, ready: @escaping (Error?) -> Void) {
        guard !isStarted else { return }
        isStarted = true
        // SSH is already connected by the caller; flush anything queued.
        ready(nil)
        relayQueue.async { [weak self] in
            guard let self else { return }
            // NOTE: no eager DNS arming — each query opens its own short-lived
            // upstream channel on demand (shared idle channels die on this
            // path, so eagerness only buys confusion).
            for pkt in self.pendingPackets {
                self.handlePacket(pkt, receive: receive)
            }
            self.pendingPackets.removeAll()
        }
        // Periodic sweep bounds ghost flows (channels that died silently).
        let timer = DispatchSource.makeTimerSource(queue: relayQueue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let n = self.stateMachine.expireIdle()
            if n > 0 {
                elog(.info, "RELAY", "sweep expired \(n) idle flow(s)")
            }
            // Stuck-SYN watch: SYN-ACK sent but phone never ACKed (or channel
            // open hung). Listed flows prove the SYN arrived AND we answered —
            // if the phone's retransmits never follow, iOS stopped feeding us.
            let stuck = self.stateMachine.stuckSynReceived(olderThan: 10)
            for flow in stuck {
                let s = flow.srcAddr.map(String.init).joined(separator: ".")
                let d = flow.dstAddr.map(String.init).joined(separator: ".")
                elog(.warning, "RELAY", "flow \(s):\(flow.srcPort) -> \(d):\(flow.dstPort) stuck SYN-RECEIVED >10s (answered, never ACKed)")
            }
            // Tunnel journal (every 30s): who talks to whom RIGHT NOW plus
            // what was dropped. The per-packet lines above show births; this
            // shows the living and the refused.
            let live = self.stateMachine.flowStats().filter { $0.state != .closed }
            if !live.isEmpty {
                let shown = live.prefix(8).map {
                    let s = $0.flow.srcAddr.map(String.init).joined(separator: ".")
                    let d = $0.flow.dstAddr.map(String.init).joined(separator: ".")
                    return "\(s):\($0.flow.srcPort)->\(d):\($0.flow.dstPort)[\($0.state)] up=\($0.upBytes) down=\($0.downBytes)"
                }.joined(separator: " | ")
                let more = live.count > 8 ? " (+\(live.count - 8) more)" : ""
                elog(.info, "RELAY", "live \(live.count) flow(s): \(shown)\(more)")
            }
            if self.droppedUDPNonDNS > 0 || self.droppedNonTCPUDP > 0 || self.droppedParse > 0 {
                elog(.info, "RELAY", "dropped/30s udp-nonDNS=\(self.droppedUDPNonDNS) nonTCPUDP=\(self.droppedNonTCPUDP) parse=\(self.droppedParse) lastDst=\(self.lastDroppedDst)")
                self.droppedUDPNonDNS = 0
                self.droppedNonTCPUDP = 0
                self.droppedParse = 0
            }
            // Parallelism journal: per-SSH-connection live channel counts.
            // Shows how the pool spread the load (ssh#1=8 ssh#2=3 ...).
            let loads = self.pool.snapshotInFlight()
            if loads.reduce(0, +) > 0 || loads.count > 1 {
                let spread = loads.enumerated().map { "ssh#\($0.offset + 1)=\($0.element)" }.joined(separator: " ")
                elog(.info, "POOL", "load [\(spread)]")
            }
            // Local DNS journal: blocks + cache hits over the last 30s.
            if self.dnsBlockedCount > 0 || self.dnsCacheHits > 0 {
                elog(.info, "DNSFILTER", "per/30s blocked=\(self.dnsBlockedCount) cacheHits=\(self.dnsCacheHits)")
                self.dnsBlockedCount = 0
                self.dnsCacheHits = 0
            }
        }
        timer.resume()
        sweepTimer = timer

        // SSH/NAT keepalive (see keepaliveTimer). Runs on the relay queue so
        // it can never race pool state.
        let ka = DispatchSource.makeTimerSource(queue: relayQueue)
        ka.schedule(deadline: .now() + 15, repeating: 15)
        ka.setEventHandler { [weak self] in
            guard let self, self.isStarted else { return }
            self.pool.keepalivePing()
        }
        ka.resume()
        keepaliveTimer = ka
    }

    func send(packet: Data, completion: @escaping (Error?) -> Void) {
        guard isStarted else {
            // SSH not ready yet — queue (bounded) so a burst at connect time
            // doesn't grow memory forever.
            if pendingPackets.count < maxPending {
                pendingPackets.append(packet)
            }
            completion(nil)
            return
        }
        // Hop onto the relay queue; the loop ignores completion anyway.
        relayQueue.async { [weak self] in
            guard let self else { return }
            self.handlePacket(packet, receive: self.receiveCallback)
        }
        completion(nil)
    }

    func stop() {
        isStarted = false
        sweepTimer?.cancel()
        sweepTimer = nil
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
        for tracked in dnsInFlight {
            (tracked as? RelayChannel)?.close()
        }
        dnsInFlight.removeAll()
        pendingPackets.removeAll()
        // Tears down EVERY pooled SSH connection (parent channels); the pool
        // itself refuses further opens afterwards.
        pool.closeAll()
    }

    // MARK: - private

    /// "a.b.c.d:port -> e.f.g.h:port" for a fresh inbound TCP SYN (SYN set,
    /// ACK clear), nil otherwise. Pure bounds-checked byte peek, no parsing.
    private func inboundSYNSummary(_ packet: Data) -> String? {
        guard packet.count >= 40 else { return nil }
        let ihl = Int(packet[0] & 0x0F) * 4
        guard ihl >= 20, packet.count >= ihl + 14 else { return nil }
        let flags = packet[ihl + 13]
        guard flags & 0x02 != 0, flags & 0x10 == 0 else { return nil }
        let s = "\(packet[12]).\(packet[13]).\(packet[14]).\(packet[15]):\(UInt16(packet[ihl]) << 8 | UInt16(packet[ihl + 1]))"
        let d = "\(packet[16]).\(packet[17]).\(packet[18]).\(packet[19]):\(UInt16(packet[ihl + 2]) << 8 | UInt16(packet[ihl + 3]))"
        return "\(s) -> \(d)"
    }

    private func handlePacket(_ packet: Data, receive: @escaping (Data) -> Void) {
        // Runs on relayQueue only (see send/start). IPv4 TCP goes through the
        // flow state machine; IPv4 UDP port 53 goes through the DNS relay;
        // everything else is dropped (the phone retransmits / falls back).
        // v6+loop counters already classify non-v4; drops below aggregate
        // into the 30s journal (per-packet QUIC spam would drown the log).
        guard packet.count >= 20, packet[0] >> 4 == 4 else { return }
        if packet[9] == 17 {
            handleDNSPacket(packet)
            return
        }
        guard packet[9] == 6 else {
            droppedNonTCPUDP += 1
            lastDroppedDst = "\(packet[12]).\(packet[13]).\(packet[14]).\(packet[15]):* -> \(packet[16]).\(packet[17]).\(packet[18]).\(packet[19]):* proto=\(packet[9])"
            return
        }
        // Full-trace: every fresh inbound SYN with headers. This is THE
        // smoking-gun line: if app SYNs never appear here while the app
        // claims timeouts, iOS is not feeding utun (not a relay bug).
        // Bounds-checked, never throws, ~1 line per connection.
        if let syn = inboundSYNSummary(packet) {
            elog(.info, "RELAY", "utun SYN \(syn)")
        }
        do {
            let replies = try stateMachine.handle(packet: IPv4Packet(Array(packet)))
            if !replies.isEmpty {
                // Log newly opened flows once each so the dump shows relay
                // activity without per-packet spam.
                if let parsed = try? IPv4Parser.parse(packet) {
                    let key = RelayFlow(srcAddr: parsed.flow.sourceAddressBytes, srcPort: parsed.flow.sourcePort,
                                        dstAddr: parsed.flow.destinationAddressBytes, dstPort: parsed.flow.destinationPort,
                                        transport: .tcp)
                    if loggedFlows.insert(key).inserted {
                        let s = key.srcAddr.map(String.init).joined(separator: ".")
                        let d = key.dstAddr.map(String.init).joined(separator: ".")
                        elog(.info, "RELAY", "flow \(s):\(key.srcPort) -> \(d):\(key.dstPort) opened")
                    }
                }
                for reply in replies {
                    self.repliesWritten += 1
                    receive(Data(reply))
                }
            }
        } catch {
            // Parse/relay errors are per-flow; don't tear down the tunnel.
            droppedParse += 1
            elog(.warning, "RELAY", "drop packet: \(error.localizedDescription)")
        }
    }

    // MARK: - DNS relay (UDP port 53 over one shared upstream TCP connection)

    /// Routes a utun IPv4/UDP packet: port-53 queries each get their OWN
    /// short-lived upstream channel (open -> query -> answer -> close).
    /// Rationale: shared idle channels die on this path (observed ~2s idle
    /// death with zero bytes in flight) for reasons outside our control
    /// (middlebox sweeps / DNS-server idle kills); per-query channels never
    /// sit idle, so the whole failure class disappears. Everything else UDP
    /// is dropped (TCP fallback covers real traffic). Runs on relayQueue only.
    private func handleDNSPacket(_ packet: Data) {
        guard let parsed = try? IPv4Parser.parse(packet),
              parsed.flow.transport == .udp else { return } // unreachable: caller checked
        guard parsed.flow.destinationPort == 53 else {
            let d = parsed.flow.destinationAddressBytes.map(String.init).joined(separator: ".")
            droppedUDPNonDNS += 1
            lastDroppedDst = "\(d):\(parsed.flow.destinationPort)/udp"
            return
        }
        let total = Int(UInt16(packet[2]) << 8 | UInt16(packet[3]))
        guard total >= 28, packet.count >= total else { droppedParse += 1; return }
        guard let udp = try? UDPParser.parse(Data(packet[20..<total])),
              !udp.payload.isEmpty else { droppedParse += 1; return }
        let flow = RelayFlow(srcAddr: parsed.flow.sourceAddressBytes, srcPort: parsed.flow.sourcePort,
                             dstAddr: parsed.flow.destinationAddressBytes, dstPort: parsed.flow.destinationPort,
                             transport: .udp)

        // ---- 1. Local rules (uBlock/hosts-style, checked BEFORE cache and
        // upstream): blocked domains answer A 0.0.0.0, overrides answer the
        // chosen IPv4; non-A questions about handled domains get REFUSED.
        // Nothing for these domains ever leaves the tunnel.
        if let name = DNSWire.questionName(from: udp.payload) {
            switch localFilter.action(for: name) {
            case .none:
                break
            case .blocked:
                dnsBlockedCount += 1
                let reply: Data? = DNSWire.questionType(from: udp.payload) == 1
                    ? DNSWire.aRecordReply(to: udp.payload, ipv4: [0, 0, 0, 0])
                    : DNSWire.refusedReply(to: udp.payload)
                if let reply, let pkt = try? UDPReplyBuilder.reply(flow: flow, payload: Array(reply)) {
                    repliesWritten += 1
                    receiveCallback(Data(pkt))
                    elog(.info, "DNSFILTER", "blocked \(name) -> A 0.0.0.0 (local, no upstream query)")
                }
                return
            case .override(let ip):
                dnsBlockedCount += 1
                let reply: Data? = DNSWire.questionType(from: udp.payload) == 1
                    ? DNSWire.ipv4Bytes(ip).flatMap { DNSWire.aRecordReply(to: udp.payload, ipv4: $0) }
                    : DNSWire.refusedReply(to: udp.payload)
                if let reply, let pkt = try? UDPReplyBuilder.reply(flow: flow, payload: Array(reply)) {
                    repliesWritten += 1
                    receiveCallback(Data(pkt))
                    elog(.info, "DNSFILTER", "override \(name) -> A \(ip) (local, no upstream query)")
                }
                return
            }
        }

        // ---- 2. Local cache: a fresh answer replays in ~0ms (id rewritten
        // to the live query). Capped at the record TTL, hard cap 300s.
        if let cached = dnsCache.answer(for: udp.payload) {
            dnsCacheHits += 1
            if let pkt = try? UDPReplyBuilder.reply(flow: flow, payload: Array(cached)) {
                repliesWritten += 1
                receiveCallback(Data(pkt))
            }
            return
        }

        var demux = DNSRelay(upstreamHost: dnsUpstream)
        guard let toSend = demux.query(udp.payload, from: flow) else { return }
        let s = flow.srcAddr.map(String.init).joined(separator: ".")
        let qid = udp.payload.count >= 2 ? String(format: "0x%02x%02x", udp.payload[0], udp.payload[1]) : "?"
        elog(.info, "RELAY", "dns query \(s):\(flow.srcPort) id=\(qid) (\(udp.payload.count)B) -> \(dnsUpstream):53")
        var channelRef: RelayChannel?
        let queryPayload = udp.payload
        channelRef = pool.open(
            flow: flow,
            onData: { [weak self] bytes in
                guard let self else { return }
                // demux is per-query local: safe to drive inline here; only
                // shared-state hops to relayQueue below.
                var answered: [(RelayFlow, Data)] = []
                for (f, resp) in demux.receive(bytes) { answered.append((f, resp)) }
                guard !answered.isEmpty else { return }
                channelRef?.close()
                guard let id = channelRef.map({ ObjectIdentifier($0 as AnyObject) }) else { return }
                self.relayQueue.async { [weak self, id] in
                    guard let self else { return }
                    self.dnsInFlight.removeAll { ObjectIdentifier($0) == id }
                    for (f, resp) in answered {
                        // Cache the answer for its (capped) TTL: repeat
                        // lookups of this name resolve locally — "optimal
                        // time" for DNS on the happy path.
                        self.dnsCache.store(query: queryPayload, response: resp)
                        if let pkt = try? UDPReplyBuilder.reply(flow: f, payload: Array(resp)) {
                            self.repliesWritten += 1
                            self.receiveCallback(Data(pkt))
                            elog(.info, "RELAY", "dns answer -> \(s):\(f.srcPort) (\(resp.count)B)")
                        }
                    }
                }
            },
            onClosed: { })
        if let channelRef {
            if dnsInFlight.count > maxDNSInFlight,
               let oldest = dnsInFlight.removeFirst() as? RelayChannel {
                oldest.close()
            }
            dnsInFlight.append(channelRef as AnyObject)
        }
        channelRef?.send(toSend)
    }
}

/// Simple random ISN generator (RFC 793 recommends 32-bit counter, but a random
/// value is fine for a relay that doesn't reuse ports).
struct RandomISN: ISNGenerator {
    func next() -> UInt32 { UInt32.random(in: 0...0xFFFFFFFF) }
}

