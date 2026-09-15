# synmasq — SYN masquerader (server side, no app changes needed)

Passive TCP/IP fingerprinting (zardaxt / proxydetect.live) scores **only the
SYN packet**. Our relay terminates the phone's TCP at the tunnel, so the VPS
kernel opens a fresh connection to each site — the site sees an **Ubuntu SYN
next to an iPhone User-Agent** ("Mismatch with User-Agent"). The iOS app
cannot influence this: the SYN is 100% server-side. This daemon fixes it
there.

## What it does

An NFQUEUE tap on `mangle/OUTPUT` diverts every egress pure-SYN to
`synmasq.py`, which rewrites it to the dominant iOS fingerprint from
zardaxt's own database (213 iOS samples) and re-injects it:

- options `M1400,N,W6,N,N,T,S,E,E,` (24 B → total length 64, offset 11)
- window 65535, wscale 6, MSS 1400, flags 194 (SYN+ECE+CWR)
- timestamp option kept with the **kernel's own TSval** (RTTM stays correct)
- `ip_id` 0; TTL/TOS/DF/ports/seq/payload pass through untouched
- checksums recomputed; only SYN-without-ACK is ever touched (fail-open:
  anything unexpected passes through unmodified)

The kernel never notices (it doesn't re-read its own SYN); peers only see a
smaller MSS and ECN-capable flags — both harmless.

## Proof (offline, reproducible)

`verify_score.py` scores a pristine Ubuntu SYN and our rewritten SYN with
zardaxt's **own** `score_fp` + database and the **trained relay model**:

| SYN | detected OS | relay prob (thr 0.8) |
|---|---|---|
| pristine Ubuntu | Chromium OS (≠ iOS → mismatch) | **0.9903 flagged** |
| masqueraded | **iOS** (matches UA) | **0.0001 not flagged** |

Run: `python3 verify_score.py` (needs `scikit-learn==1.7.2` for the model
half; the database half needs only stdlib + network).

## Deploy (needs root on the VPS)

```sh
scp -r synmasq root@VPS:/tmp/synmasq
ssh root@VPS 'cd /tmp/synmasq && ./install.sh'
```

Then from an iPhone **via the VPN**: https://proxydetect.live/tcpip.html →
expect `TCP/IP Detected OS = iOS` + green "Matches User-Agent".

Rollback: `systemctl disable --now synmasq` (ExecStopPost removes the taps).

## What this does NOT fix

IP/ASN reputation verdicts ("datacenter IP") are a different layer — the
egress IP stays the VPS's. If a site *also* flags the ASN, that needs
residential egress, not fingerprint work.
