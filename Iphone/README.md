# SSH2VPN — iPhone

Native iOS client for the Personal VPN product. The client exposes a system
VPN through `NetworkExtension`; its data plane relays IPv4 TCP flows (plus a
DNS relay for UDP port 53) over standard SSH `direct-tcpip` channels to the
user's VPS. **The server needs nothing but `sshd`** — no root, no TUN, no
gateway software.

## Current implementation

- `Sources/VPNCore` (Swift package `SSH2VPN`, Swift 6, iOS 16+) contains the
  transport and connection logic: `TransportFrame` framing, SSH connection
  pool, relay state machines (`TCPRelayStateMachine`, `TCPSequence`), DNS
  presets + local DNS filter, server store, configuration builder, app
  settings codec, ad quota, tunnel self-test, diagnostics helpers.
- `App/PacketTunnelProvider.swift` is the Network Extension: parses TCP from
  `utun`, opens `direct-tcpip` channels on a demand-grown SSH pool
  (max 4 connections), answers DNS locally/through per-query upstream
  channels, writes well-formed replies back to `packetFlow`.
- Extension-owned multi-server API over `handleAppMessage`
  (`TunnelAppMessageRouter`): server list CRUD, status/stats, log export.
- `App/RootView.swift` — SwiftUI UI: Connect tab (power button, world map,
  live stats strip), Locations, Settings (Protocol/DNS/Advanced), Hacker
  Console sidebar; 17 built-in languages; adaptive iPhone-landscape/iPad
  layout; light/dark mode, Dynamic Type, VoiceOver labels.
- Free-time quota: 3 h per install, +3 h per rewarded-ad view (ad itself is
  a stub), 1 view/hour, max 3 banked.
- `Gateway/gateway.py` — the superseded TUN-mode gateway (still bundled,
  not invoked; see ARCHITECTURE.md "History").
- `Tests/VPNCoreTests` — 525 tests (2 skipped) for framing, state machines,
  pool policy, DNS filter/presets, settings codecs, quota, deploy
  coordinators, server store.
- `Gateway/test_gateway.py` — Python tests for the legacy gateway.

## Run the core tests

```sh
cd Iphone
SWIFT_MODULECACHE_PATH=/tmp/personalvpn-swift-modules \
CLANG_MODULE_CACHE_PATH=/tmp/personalvpn-clang-modules \
swift test --disable-sandbox
```

Last verified: 525 tests, 0 failures (1.1 s).

## Build the app (signed device build)

```sh
xcodebuild build -project SSH2VPN.xcodeproj -scheme SSH2VPN \
  -destination 'generic/platform=iOS' -configuration Debug
```

Signing comes from the project (DEVELOPMENT_TEAM = 326TF9BQ3C). See
`App/BUILD_RULES.md`: never build with `CODE_SIGNING_ALLOWED=NO`,
`CODE_SIGN_IDENTITY="-"`, or simulator destinations — unsigned builds reset
the local Apple Developer team session.

The real `NEPacketTunnelProvider` lifecycle, VPN entitlement, background
reconnect, and App Store signing must be verified with an Apple Developer
team and a physical iPhone. Simulator tests cannot prove those behaviors.

## Docs

- `ARCHITECTURE.md` — data-plane architecture, invariants, history of the
  TUN mode.
- `CHECKLIST.md` — delivery checklist status.
- `IMPLEMENTATION_PLAN.md` — remaining TDD work items.
- `Docs/device-logs/` — captured device verification logs.
