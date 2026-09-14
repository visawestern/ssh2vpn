# SSH2VPN — Changelog

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
