# SSH2VPN — Changelog

## dev (unreleased)

Site-side anti-fingerprinting, rootless partial:

- **Gateway MSS clamp.** `Iphone/Gateway/gateway.py` now opens outbound
  TCP sockets with `TCP_MAXSEG = 1400` (kernel already advertises 1460,
  which read as "desktop Linux"). Pure per-socket socket option — no
  privileges on the egress box. Proven live on the VPS: `getsockopt`
  shows the clamp on, `ss -ti` `mss` drops 32768 → 1388 on loopback.
  Honest limit: this narrows the gap to zardaxt's iOS fingerprint
  (M1400/W6/65535/194/len64) but cannot pass it, because window scale,
  ECN flags, IP id and packet length are still kernel-chosen.
- **`Iphone/Gateway/synmasq/`** (code only, needs 1-time root to deploy):
  NFQUEUE rewrite of egress SYNs to zardaxt's dominant iOS template.
  Offline proof with zardaxt's own DB + trained model: relay probability
  0.9903 → 0.0001. Parked — deployment requires root on the egress box;
  our reviewer account is not in sudoers and no root is available.

## 1.0.5 (build 6)

Crowd camouflage: the tunnel now handshakes like a Termux admin's OpenSSH 9.6.

- **Spoofed plaintext handshake (TSPU-visible bytes).** Vendored
  swift-nio-ssh 0.15.0 fork (`Iphone/Vendor/`, path dependency, no public
  remote): version banner `SSH-2.0-OpenSSH_9.6`, KEXINIT proposal order
  curve25519-first / aes128-gcm-first / nistp256-before-384 (OpenSSH 9.6
  relative order among implemented primitives), channel max packet size
  32768. Loopback golden test asserts the actual wire bytes.
- **Protocol keepalive replaces the channel dance.** One
  `keepalive@openssh.com` global request per connection per 60s (suppressed
  while user traffic flows) — the exact bytes `ssh -o ServerAliveInterval`
  sends. Any server reply (SUCCESS or RFC-mandated FAILURE) counts as
  alive; only silence feeds dead-peer detection. No MaxSessions slot burned.
- **Rekey on OpenSSH's 4G/1h schedule.** Pool counts relayed bytes per
  connection and rotates session keys via the fork's new `rekey()` API.
- **Upstream NIOSSH bug fixed in the fork.** Channel opens attempted
  mid-rekey wedged forever (state machine throws, error swallowed, promise
  never resolves). Opens now wait for the return to `.active`; disconnect
  still fails fast. All 346 fork tests green.
- **Probe chain hardened.** User DNS first, then 3 independent public
  resolvers + :443, localhost fallback with 3 distinct verdicts
  (forwarding disabled / egress blocked / auth stuck).
- Tests: 705 pass + 4 live proofs against stock OpenSSH 9.6p1
  (handshake interop, keepalive round-trip, rekey survival).

## 1.0.4 (build 5)

Anti-fail2ban: the app no longer hammers the server with doomed attempts.

- **Auth/host-key failures are fatal (no auto-retry).** The extension maps
  typed failures to stable codes (`authFailedExhausted` when the server
  rejects all offered credentials, `hostKeyMismatch`, `forwardingRefused`
  for the probe) and persists them; the app classifier treats these as
  fatal — exactly 1 attempt per manual tap instead of 3×N. Raw
  localizedDescriptions carry no case info, so the mapping is the whole
  fix. Generic/vague auth strings stay transient (breaker-capped).
- With the 1.0.2 breaker (10-attempt cap) this means fail2ban's default
  `maxretry 5` can no longer be reached by the app alone.
- Tests: +3 classifier cases (typed codes fatal, generic string still
  transient). Full suite 621 pass.

## 1.0.3 (build 4)

Crash fix: the extension died in `ssh-connect` on every start.

- **Root cause (device crash log).** `extractSSHHandler` read the NIO
  pipeline via `syncOperations` from the start-sequence queue — off the
  channel's event loop. Release builds silently tolerate it; DEBUG builds
  trap (`EventLoop.preconditionInEventLoop` → SIGTRAP), so the locally
  installed 1.0.1/1.0.2 builds could never connect. Fixed by hopping to the
  event loop first (`.wait()` off-loop; direct path preserved on-loop).
- Installed builds now match store behavior; the latent trap is gone in
  every configuration.

## 1.0.2 (build 3)

Connect-storm circuit breaker (the 1.0.1 reconnect loop could pile
concurrent SSH handshakes onto the server until every attempt died).

- **Circuit breaker (NEW, as requested).** After 10 consecutive failed
  attempts the app disables connect-on-demand at the NE level (saved, so iOS
  stops relaunching a dead tunnel) and parks the app-side redial — while
  `killSwitch` stays ON in settings. Fatal failures count too (a doomed
  password must not hammer either). A manual Connect or any success re-arms.
  (`ConnectionBreaker`, BREAKER log tag)
- **No-duplicate-start guard.** A start is skipped when the live manager is
  already connecting/connected/reasserting — stacking another startTunnel
  murders the in-flight SSH handshake, which fed the storm.
- **Quota-refusal visibility.** The extension's quota gate now persists
  `quotaExhausted` to the shared error record (was: silent death with
  extError=none and blind retries).
- BOOT log line reads the version from the bundle (was hardcoded v1.0.0).

## 1.0.1 (build 2)

Connection speed + DNS latency, no behavior changes for the user.

- **Warm channel pre-open (TCP).** Repeat and parallel connections to a
  recently-busy host skip the cold SSH channel open (one SSH round trip +
  server-side TCP handshake). Only *virgin* (never-used) channels are parked:
  reusing a channel that already carried a TLS session would corrupt the new
  handshake, so used channels close exactly like before. Warming arms after
  2 clean closes to the same host within 15s, max 4 parked channels with a
  20s TTL, only when the SSH pool has spare capacity; dirty or dead standbys
  are dropped, never handed out. (`WarmChannelPool`, WARM log tag)
- **DNS cache v2.** Negative answers are now cached via the authority SOA TTL
  (NXDOMAIN/NODATA capped at 60s, SERVFAIL at 10s) — previously every miss
  re-queried upstream. AAAA answers are cached too (previously only A, so
  half of every dual-stack lookup missed). Capacity 512 → 2048 entries.
  Cache hits with < 15s TTL left trigger a background upstream re-query
  (early-refresh): the phone keeps getting the instant cached answer while
  the entry is silently renewed, so hot names never pay a cold miss.
- **SSH pool tuning.** `channelsPerConnection` 4 → 9 (sshd `MaxSessions(10)`
  minus 1 slot always reserved for keepalive) and the per-connection
  keepalive ping is now mandatory on every pooled stream.

## 1.0.0 (build 1)

Initial App Store release: system VPN over plain SSH (NetworkExtension),
parallel SSH connection pool, transparent TCP relay, local DNS relay with
blocklist/overrides and TTL cache, multi-server management, 17 languages.
