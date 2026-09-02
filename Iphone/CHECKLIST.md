# iPhone application delivery checklist

## Product boundary

- [x] The app uses the user's own VPS; our backend is never in the traffic path.
- [x] SSH is only the encrypted transport and bootstrap mechanism; no `ssh -D` or OpenSSH forwarding is required.
- [x] The VPS gateway is a user-owned, temporary userspace process. The owner can inspect, stop, replace, or remove it.
- [x] MVP implements TCP, UDP, IPv4/IPv6, DNS, reconnect, and full allowed device traffic through `NetworkExtension`; device proof remains required.

## Transport and protocol

- [x] Length-prefixed, versioned frames with explicit flow IDs.
- [x] `OPEN`, `DATA`, `FIN`, `RESET`, `CLOSE`, `PING`, and `PONG` frame types.
- [x] Symmetric Python gateway contract for stdin/stdout SSH exec channels.
- [x] TCP gateway end-to-end integration test against a localhost echo server.
- [x] UDP gateway end-to-end integration test against a localhost datagram echo server.
- [x] Raw IP packet frame contract for system-wide packet tunnel.
- [x] Gateway raw packet mode opens a Linux TUN device on demand.
- [x] Define SSH library and license for iOS (SwiftNIO SSH, Apache-2.0 dependency; host-key pinning required).
- [x] Implement raw-packet SSH connection pool with bounded queues (flow-mode pinning remains separate).
- [x] Open three independent SSH child sessions for raw packet distribution; reconnect is backoff-driven.
- [x] Implement SSH child-channel framing codec.
- [x] Never multiplex all traffic through one SSH TCP connection in raw-packet mode.
- [x] Implement TCP half-close and UDP idle-expiry semantics with explicit FIN/CLOSE behavior.
- [x] Implement protocol authentication handshake and replay protection (per-session nonce, exact ACK, stream-zero check, duplicate ACK rejection).
- [x] Implement bounded packet queue/backpressure, frame/payload/host/flow limits, connect timeout, and TCP/UDP idle timeouts.
- [x] Add deterministic malformed protocol corpus coverage; libFuzzer/long-running fuzz job remains a CI hardening task.

## iOS system VPN

- [x] Create an iOS app target and a Network Extension target.
- [x] Enable the `Network Extension` / packet tunnel entitlement.
- [x] Implement `NEPacketTunnelProvider`.
- [x] Read raw IPv4/IPv6 packets from `packetFlow`; system-wide packet mode forwards them without lossy user-space reclassification.
- [x] Send/receive `.packet` frames through the SSH child channel.
- [x] Configure VPS TUN address, forwarding, and NAT with reversible bootstrap.
- [x] Route all allowed traffic through the tunnel (physical leak test remains required).
- [x] Exclude the configured VPS host route from the tunnel to prevent SSH recursion; hostname resolution and a device test remain required.
- [x] Resolve VPS hostnames before installing tunnel settings and exclude every resolved IPv4/IPv6 address; device-level route verification remains required.
- [x] Apply full-tunnel DNS settings; DNS leak validation remains a device/network test.
- [x] Request full-network route inclusion and route enforcement from `NETunnelProviderProtocol`; physical leak/kill-switch proof remains required.
- [x] Handle `startTunnel`, `stopTunnel`, sleep/wake, extension termination, and re-entry hooks (device validation remains).
- [x] Persist only non-secret profile metadata in App Group storage.
- [x] Store password and normalized Ed25519 private-key credentials in Keychain.

## VPS bootstrap

- [x] Coordinate one remote TUN ownership/broker across the three SSH raw-packet sessions; broker ownership/peer packet routing is covered by an integration test, while real Linux multi-process validation remains required.
- [x] SSH-connect using user-supplied address, port, and password with pinned host key.
- [x] Add Ed25519 private-key authentication and secure in-memory import; unsupported encrypted/algorithm formats are rejected explicitly.
- [ ] Validate OS, architecture, permissions, and outbound connectivity.
- [ ] Prefer streaming a signed Go binary over SSH or running a compatible Python gateway from stdin.
- [x] Do not require a public gateway listener.
- [ ] Verify artifact signature/hash before execution.
- [ ] Add explicit install/temporary-session/remove modes.
- [ ] Clean temporary artifacts on normal disconnect and failed setup.
- [x] Make gateway behavior transparent to the VPS owner.

## Reliability and edge cases

- [x] SSH handshake/connect timeout.
- [x] Wrong password/key produces an explicit authentication failure.
- [x] Host key changed is rejected by pinning.
- [x] SSH port unavailable produces a connection failure.
- [x] Missing Python/permission/outbound failure is surfaced as gateway or transport failure.
- [ ] Partial upload/interrupted bootstrap.
- [x] Gateway exits unexpectedly triggers session failure and bounded reconnect after readiness.
- [x] One SSH transport connection can die while other pool sessions remain alive.
- [x] Wi-Fi → cellular and cellular → Wi-Fi transitions trigger controlled socket teardown/reconnect; physical carrier test remains required.
- [ ] Device sleep/wake and app suspension.
- [ ] DNS failure, MTU issues, packet loss, and captive portals.
- [ ] IPv4-only VPS and unsupported IPv6 paths.
- [ ] Memory pressure and maximum flow count.
- [x] User disconnects during connect cancels pending packet completions and transport setup.
- [x] Repeated reconnect with bounded exponential backoff and jitter.

## UI and localization

- [x] First-launch language overlay with flag buttons and accessible language names.
- [x] Persist language choice and provide a Settings language switch.
- [x] Localize the current UI copy in English, Russian, Spanish, German, Japanese, and Chinese.
- [x] Home screen with one clear Connect action and current server status.
- [x] Add Existing Server flow.
- [x] Server detail and diagnostics screens.
- [x] Setup progress: Connecting → Preparing → Testing → Ready.
- [x] Human-readable errors with expandable technical details.
- [x] Light/dark mode, Dynamic Type, VoiceOver labels, and reduced-motion handling.
- [x] Apple-style material hierarchy, restrained motion, and immediate press feedback.

## TDD and verification

- [x] Unit tests for transport frame encoding/decoding.
- [x] Red tests for malformed input and oversized frames.
- [x] Unit tests for connection state transitions.
- [x] Unit tests for reconnect backoff and jitter bounds.
- [ ] Integration tests with a disposable Linux VPS.
- [ ] TCP/UDP end-to-end tests through the real gateway.
- [ ] Packet capture tests proving traffic exits from the VPS.
- [ ] DNS leak tests.
- [ ] Physical-device background and sleep/wake tests.
- [ ] Network Link Conditioner tests.
- [ ] Crash/relaunch while VPN is active.
- [ ] TestFlight beta with multiple carriers and Wi-Fi networks.
- [ ] App Store review and VPN privacy compliance review.
