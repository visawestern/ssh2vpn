# iPhone application delivery checklist

> Status synced 6 Sep 2026. The data plane is the unprivileged relay
> (TCP over SSH direct-tcpip + DNS relay); the server-side TUN/gateway mode
> is superseded — items that applied to it are marked accordingly.

## Product boundary

- [x] The app uses the user's own VPS; our backend is never in the traffic path.
- [x] SSH is only the encrypted transport; no `ssh -D` or OpenSSH forwarding is required (direct-tcpip channels are opened by the app itself).
- [x] The server needs no software beyond stock `sshd` with `AllowTcpForwarding`; the VPS owner keeps full control of the box.

## Transport and protocol (VPNCore)

- [x] Length-prefixed, versioned frames with explicit flow IDs (`TransportFrame`).
- [x] `OPEN`, `DATA`, `FIN`, `RESET`, `CLOSE`, `PING`, and `PONG` frame types.
- [x] SSH child-channel framing codec (`SSHFrameCodec`), tested against fragmentation.
- [x] TCP relay state machine with sequence tracking, window scaling, backpressure, half-close semantics (`TCPRelayStateMachine`, `TCPSequence`, `TCPRelayTests`).
- [x] UDP reply builder with valid checksums (`UDPReplyBuilder`) — used by the DNS relay.
- [x] Protocol authentication handshake and replay protection (`SessionHandshake`: per-session nonce, exact ACK, stream-zero check, duplicate ACK rejection) — legacy mode path, still unit-tested.
- [x] Bounded frame queues, payload/host/flow limits, connect timeout, idle timeouts (`GatewayFrameQueue`, `RetryBudget`, `PingBudget`, `HeartbeatTracker`).
- [x] Deterministic malformed-protocol corpus coverage (`TransportFuzzTests`); long-running libFuzzer job remains a CI hardening task.
- [x] Parallel SSH connection pool (`SSHConnectionPool`): starts with 1 authenticated connection, grows on saturation, max 4; every new flow picks the least-loaded connection.
- [x] Pre-flight forwarding probe before tunnel install (one throwaway direct-tcpip open to 8.8.8.8/1.1.1.1:53) — no half-installed blackholed tunnels.
- [x] MSS segmentation toward the phone for throughput.

## Server-side TUN gateway (superseded — legacy path kept in tree)

- [x] Symmetric Python gateway contract for stdin/stdout SSH exec channels (TCP + UDP e2e tests against localhost echo servers, `Gateway/test_gateway.py`).
- [x] Raw IP packet frame contract; gateway opens a Linux TUN device on demand; single Unix-socket TUN broker across three SSH sessions (integration-tested).
- [x] Binary deployment modules in VPNCore: signed-artifact verifier (`GatewayArtifactVerifier`, Ed25519 + key rollover), deployment mode selector, deploy coordinator with install/temporary/remove modes, checkpoint retry policy, artifact paths/fingerprints — all unit-tested, not on the active path.
- [ ] Streaming a signed Go binary on real VPS (superseded by relay mode; only relevant if TUN mode returns).

## iOS system VPN

- [x] App target `SSH2VPN` + Network Extension target `PacketTunnel` (com.ssh2vpn.app.packet-tunnel), hand-authored Xcode project.
- [x] Packet tunnel entitlement enabled; Keychain access group sharing for the last error.
- [x] `NEPacketTunnelProvider` implemented with cancellable mid-connect start (checkpoints after SSH connect and after the forwarding probe).
- [x] Read IPv4 packets from `packetFlow`; TCP flows relayed over direct-tcpip; protocol split counters (v4tcp/v4udp/v4other/v6/nonIP) reported to the app.
- [x] DNS: local rules (block → 0.0.0.0 / override → custom IP) applied before any upstream query; per-query upstream DNS channels; TTL-capped cache; custom DNS or one of 19 curated public presets (mutually exclusive modes), IPv4-literal validation.
- [x] Unique tunnel device addresses per install (TunnelDevice-derived) to avoid LAN subnet collisions.
- [x] IPv4-only tunnel settings (v6 deliberately not installed); IPv6 classified and dropped gracefully.
- [x] Kill switch (includeAllNetworks + enforceRoutes), on-demand rules, logging toggle — every setting wired to real behavior.
- [x] Extension-owned server list with Keychain credentials; secrets never sent over app messages unless explicitly provided.
- [x] Live stats over `handleAppMessage`: SSH connections, channels, flows, MB up/down, tunnel phase, utun counters (2 s polling).
- [x] Zombie-tunnel watchdog: dead utun after disconnect → profile removal restores internet.
- [x] Stall watchdog: minutely ping + `lastReadAt` distinguishes idle from dead packet flow.
- [x] SSH/NAT keepalive every 15 s keeps pooled connections alive on flaky Wi-Fi.
- [x] Auto-reconnect with bounded backoff, quota-aware; early-death diagnosis with bounded auto-retry on connect.
- [ ] Device sleep/wake long-duration test remains required (loop suspend/resume implemented).
- [ ] Physical leak/kill-switch packet-capture proof remains required.

## VPS requirements validation

- [x] `VPSEnvironmentValidator` (OS family, architecture, python availability, outbound connectivity) — implemented and unit-tested (legacy path for TUN mode).
- [x] Host key pinning; password + Ed25519 key auth; encrypted keys and unsupported algorithms rejected explicitly.
- [x] Hostname resolution before tunnel start; SSH port/host failures surface as explicit errors.

## Reliability and edge cases

- [x] SSH handshake/connect timeout; wrong password/key → explicit auth failure; host key change rejected by pinning.
- [x] Forwarding disabled on server (AllowTcpForwarding=no) → explicit probe failure with human-readable cause.
- [x] User disconnect during connect cancels pending work at checkpoints (no half tunnel).
- [x] Repeated reconnect with bounded exponential backoff and jitter.
- [x] Reconnect backlog coalescing; pre-invoke stale disconnect ignored (first-tap ghost).
- [x] Extension unreachable / app-message timeout degrades to empty result, never hangs.
- [ ] Wi-Fi → cellular transition on physical carrier test remains required (NWPathMonitor-driven reconnect implemented).
- [ ] Memory pressure / maximum flow count under load — needs profiling pass.
- [ ] Crash/relaunch while VPN active.

## UI and localization

- [x] First-launch language overlay with flag buttons and accessible language names.
- [x] Persist language choice; Settings language switch; 17 languages fully localized (en, ru, es, de, fr, it, pt-BR, ja, zh-Hans, ko, ar, hi, th, tr, pl, nl, vi).
- [x] Home screen with one Connect action, live status, world map, server card with GeoIP country/flag.
- [x] Add/Edit Existing Server flow with test connection, host key pinning, dedupe.
- [x] Server list (Locations tab), selection, deletion, server-switch without deadlock; per-server ping display.
- [x] Settings: Protocol (SSH2-only, explained), DNS (custom or 19 public presets with capability chips + tooltips), Advanced (kill switch, on-demand, logging) — every toggle does what it says.
- [x] Diagnostics screen with live phase/counter refresh, sanitized console log, exportable via Hacker Console sidebar.
- [x] Free-time quota UI: remaining time strip, watch-ad (+3 h) with cooldown, localized quota-exhausted error.
- [x] Adaptive layout: iPhone rotation + iPad 10–13" centered column; scrollable compact-height screens.
- [x] Light/dark mode, Dynamic Type, VoiceOver labels, reduced-motion handling, Apple-style materials.

## TDD and verification

- [x] Unit tests for transport frame encoding/decoding, malformed input, oversized frames (525 tests green, 2 skipped).
- [x] Unit tests for connection state transitions, reconnect backoff and jitter bounds, pool policy, relay flow machines, DNS filter, presets, quota, server store, codecs.
- [x] Python tests for the legacy gateway (639-line suite).
- [ ] Integration tests with a disposable Linux VPS (relay-mode e2e over real sshd).
- [ ] Packet capture proving traffic exits from the VPS (device lab).
- [ ] DNS leak tests on physical networks.
- [ ] Physical-device background and sleep/wake tests.
- [ ] Network Link Conditioner pass.
- [ ] TestFlight beta with multiple carriers and Wi-Fi networks.
- [ ] App Store review and VPN privacy compliance review.

## Out of current scope (product stages not started)

- VPS provisioning adapter, provider abstraction, backend licensing/trial/orders (ТЗ Этапы 3–4).
- In-App Purchase of servers / lifetime license (Этап 6).
- Multi-hop chains (Этап 9), TLS transport (Этап 10).
- Server expiration/extend/replace UI (no expiration fields in the store yet).
