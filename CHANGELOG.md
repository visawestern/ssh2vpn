# SSH2VPN — Changelog

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
