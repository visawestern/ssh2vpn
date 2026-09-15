# Review Notes — paste into App Store Connect (edit bracketed parts)

Test server (valid until 29.10.2026):
Host: 192-250-228-44.sslip.io (resolves to 192.250.228.44; use the hostname
so the test also works on IPv6-only networks — the app dials by hostname) /
Port: 22 / Username: [SSH_USER] / Password: [SSH_PASS]
Auth type: Password (leave the private-key field empty).
Steps: open the app → dismiss the language screen → read and accept the
privacy disclosure → Add Server → enter the above → Save → tap the power
button → status becomes PROTECTED.

Free tier: every install includes 1 free hour of tunnel time. The hour starts
on FIRST USE (first Connect tap or first rewarded ad) — never on install —
and counts down in real time, even with the VPN off. The +3h button plays a
Google AdMob rewarded ad and adds 3 hours (max once per hour, max 12 banked).
Ads are offered only while the VPN is disconnected. If no ad is available,
the app shows a short notice and grants nothing.

Purchases (both one-time, non-consumable): Unlimited ($10) removes the time
limit and ads forever. The FIRST paywall opening shows a one-time $6 intro
offer; every later opening shows the regular $10 price. Closing always just
closes — no timers, no locked buttons. Restore Purchase is in Settings and
on the paywall.

Notes: the app is a client for the reviewer's/user's own server (no servers
of ours). DNS filter lists download only when the user subscribes. Tunnel
self-checks query api.ipify.org / ifconfig.me / Google generate_204 to
confirm traffic exits through the configured server.
