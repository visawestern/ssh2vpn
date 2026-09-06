# iPhone implementation architecture

> Updated 6 Sep 2026 after the relay-mode switch. The old TUN/gateway data
> plane described here previously no longer runs — see "History" at the end.

## Data plane (current: unprivileged relay mode)

`NEPacketTunnelProvider` owns the system VPN interface (`utun`). Instead of
shipping raw IP packets to a server-side gateway, the extension **parses TCP
flows locally and relays them over standard SSH `direct-tcpip` channels** to
the user's VPS. No root, TUN device, NAT, or server-side software is required
— the server only needs a stock `sshd` with `AllowTcpForwarding` enabled.

Key pieces:

- `RelayTransport` (`App/PacketTunnelProvider.swift`) — `TCPRelayStateMachine`
  + `TCPSequence` track IPv4 TCP flows; each flow opens a `direct-tcpip`
  channel on the least-loaded pooled SSH connection.
- `SSHConnectionPool` (`Sources/VPNCore/`) — parallel SSH connections to the
  same server (starts with 1, grows on demand, max 4 by `SSHPoolPolicy`).
  New flows/DNS queries pick the least-loaded connection.
- DNS: UDP port 53 is answered by an in-extension **DNS relay** — each query
  gets its own upstream TCP channel to the configured resolver. Local rules
  (block/override) are applied before any upstream query; a TTL-capped cache
  avoids repeat lookups. Non-DNS UDP and non-TCP/UDP v4 traffic is counted and
  dropped (logged, not crashed).
- IPv6: the relay is IPv4-only. v6 tunnel settings are deliberately not
  installed (`settings.ipv6Settings = nil`); v6 counters classify the drops.
- Reply path: `UDPReplyBuilder`/relay replies are written back to `packetFlow`
  with valid checksums; MSS is segmented toward the phone.

Transport invariants (unchanged): pinned host key, Ed25519/password auth,
bounded queues, reconnect only after a real readiness probe (one throwaway
`direct-tcpip` open to 8.8.8.8/1.1.1.1:53 proves auth + forwarding before the
tunnel is installed — no half-installed blackholed tunnels).

## App ↔ extension contract

The extension owns the authoritative server list (`TunnelServerStore`) and
exposes it over `handleAppMessage` via `TunnelAppMessageRouter` commands:
`status`, `lastError`, `logs`, `serverList/Get/Set/Delete/Select`. The app
side (`VPNExtensionAPI`) polls status/stats every 2 s while connected (SSH
conns, channels, flows, MB up/down, protocol split, tunnel phase) and pulls
extension console logs through the same channel — no App Group needed.
`TunnelLastError` shares the last error through the Keychain access group.

## Self-healing / background survival

- SSH/NAT keepalive: one throwaway `direct-tcpip` open every 15 s keeps
  pooled connections visibly active on flaky NATs.
- App-side zombie-tunnel watchdog: detects a dead `utun` that iOS kept after
  disconnect and removes the profile to restore connectivity.
- Stall watchdog: the app pings every minute and compares `lastReadAt` from
  the packet loop to distinguish "user idle" from "iOS stopped feeding the
  tunnel".
- Cancellable mid-connect start with checkpoints (post-SSH, post-probe) so a
  disconnect during connect never leaves half a tunnel.
- Kill-switch reconnect + auto-connect retry are quota-aware (see below).

## Free-time quota

`AdQuota` (VPNCore) — every install gets 3 h of VPN time; one rewarded-ad
view (currently a stub) adds +3 h; views are rate-limited (1/hour, max 3
banked). Enforcement is app-side; connect is blocked and the tunnel
disconnects when exhausted.

## UI/UX structure

SwiftUI app (`SSH2VPN` target, bundle `com.ssh2vpn.app`; extension bundle
`com.ssh2vpn.app.packet-tunnel`; deployment target iOS 16.0). `RootView`
holds three tabs — Connect (power button, world map, server card, stats
strip), Locations (server list + add), Settings (Protocol/DNS/Advanced +
language). A right-sliding "Hacker Console" sidebar shows the sanitized
console log. Adaptive layout: iPhone portrait edge-to-edge; iPhone landscape
and iPad 10–13" get a centered 720 pt column. Copy is in-code localized
(`Copy`/`CopyDNS`/`AppLanguage`) for 17 languages: en, ru, es, de, fr, it,
pt-BR, ja, zh-Hans, ko, ar, hi, th, tr, pl, nl, vi.

## Server-side requirements (current)

None beyond `sshd`: `AllowTcpForwarding` (default `yes`), password or
Ed25519 key auth, outbound TCP. `Gateway/gateway.py` remains in the repo and
is bundled in the extension, but the TUN/raw-packet path it implements is
not invoked (see History).

## History: TUN/gateway mode (superseded)

The first data plane streamed `.packet` frames over three SSH child
sessions to a `gateway.py` process that wrote them into a Linux TUN device
(one gateway owned the TUN, others joined over a permission-600 Unix
socket; return packets were round-robin assigned). It works only with root
on the VPS, so production switched to the unprivileged relay above.
`Gateway*` deploy/verify modules (`GatewayDeploymentOrchestrator`,
`GatewayArtifactVerifier`, install/remove modes, checkpoint resume) are
still unit-tested in VPNCore but are not on the active path.

## Bootstrap modes (superseded, kept for reference)

- Python stdin mode: stream a signed/embedded gateway script to a
  compatible `python3 -` process.
- Binary mode: stream a signed Go binary through SSH, verify it, execute it
  from a temporary path, then clean it up.

The app does not require `ssh -D`, `ssh -L`, `ssh -R`, or a public proxy
port — this invariant holds in relay mode by construction.

## iOS limits

The app target and Network Extension target are separate Xcode targets in
the hand-authored `SSH2VPN.xcodeproj` (scheme `SSH2VPN`, DEVELOPMENT_TEAM
`326TF9BQ3C`; see `App/BUILD_RULES.md` — signed device builds only, no
`CODE_SIGNING_ALLOWED=NO`, no simulators). `PacketTunnelProvider` behavior
(entitlements, extension lifetime, background reconnect, sleep/wake,
network transitions) must be verified on a physical iPhone.
