#!/usr/bin/env python3
"""Build the offline IP -> country database for SSH2VPN.

Reads the five RIR delegated-stats files (downloaded once into --input,
or fetched now if missing) and writes a compact binary table:

    magic   "GEO1" (4 bytes)
    v4count UInt32 BE, then per entry: network UInt32 BE, prefixlen UInt8,
                                       countryIdx UInt16 BE   (7 bytes each)
    v6count UInt32 BE, then per entry: hi UInt64 BE, lo UInt64 BE,
                                       prefixlen UInt8, countryIdx UInt16 BE
    cccount UInt16 BE, then per country: 2 bytes ASCII (ISO-3166, e.g. DE)

Lookup is longest-prefix-match, done fully on-device: the app never sends
the server address to any geo service (App Review 5.1.1 / 5.4 safe).

Only `allocated` / `assigned` ranges are kept. Special-use space (RFC1918,
loopback, multicast...) is not in these files and, even if it were, the
app checks private/loopback before consulting the table.

Re-run monthly to refresh:  python3 scripts/build_geoip.py
Outputs: Iphone/Sources/VPNCore/Resources/geoip.dat
"""

import ipaddress
import os
import struct
import sys
import tempfile
import time
import urllib.request

RIR_URLS = {
    "ripencc": "https://ftp.ripe.net/ripe/stats/delegated-ripencc-latest",
    "apnic": "https://ftp.apnic.net/stats/apnic/delegated-apnic-latest",
    "arin": "https://ftp.arin.net/pub/stats/arin/delegated-arin-extended-latest",
    "lacnic": "https://ftp.lacnic.net/pub/stats/lacnic/delegated-lacnic-latest",
    "afrinic": "https://ftp.afrinic.net/pub/stats/afrinic/delegated-afrinic-latest",
}

# Non-ISO codes seen in RIR data mapped to ISO-3166 (or dropped).
CC_FIX = {"UK": "GB"}
CC_DROP = {"*", "", "EU", "AP"}  # regional/summary placeholders, no centroid

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Machine-independent cache: RIR stats are re-downloaded when missing or
# when the output table is older than --max-age-days (default 30).
DEFAULT_INPUT = os.path.join(tempfile.gettempdir(), "ssh2vpn-geoip")
DEFAULT_OUT = os.path.join(REPO, "Iphone", "Sources", "VPNCore", "Resources", "geoip.dat")


def fetch_inputs(d):
    os.makedirs(d, exist_ok=True)
    for name, url in RIR_URLS.items():
        p = os.path.join(d, name + ".txt")
        if os.path.exists(p) and os.path.getsize(p) > 500_000:
            print(f"cached {name} ({os.path.getsize(p)} bytes)")
            continue
        print(f"downloading {name} ...")
        urllib.request.urlretrieve(url, p)
        print(f"  {os.path.getsize(p)} bytes")


def ipv4_range_to_cidrs(start_int, count):
    """Expand [start, start+count) into minimal CIDR list."""
    out = []
    end = start_int + count
    cur = start_int
    while cur < end:
        # largest aligned block at cur
        if cur == 0:
            tz = 32
        else:
            tz = (cur & -cur).bit_length() - 1
        max_len = 32 - tz
        # largest block that fits into remaining
        remain = end - cur
        while (1 << (32 - max_len)) > remain:
            max_len += 1
        out.append((cur, max_len))
        cur += 1 << (32 - max_len)
    return out


def parse(input_dir):
    v4 = {}  # (network, plen) -> cc
    v6 = {}  # (hi, lo, plen) -> cc
    dup = 0
    per_rir = {}
    for name in RIR_URLS:
        p = os.path.join(input_dir, name + ".txt")
        n4 = n6 = 0
        for line in open(p, encoding="utf-8", errors="ignore"):
            if line.startswith("#") or line.startswith("2.3") or "|" not in line:
                continue
            f = line.strip().split("|")
            if len(f) < 7:
                continue
            _, cc, typ, start, val, _date, status = f[:7]
            if status not in ("allocated", "assigned"):
                continue
            cc = CC_FIX.get(cc, cc)
            if cc in CC_DROP:
                continue
            if len(cc) != 2 or not cc.isalpha():
                continue
            cc = cc.upper()
            try:
                if typ == "ipv4":
                    base = int(ipaddress.IPv4Address(start))
                    for net, plen in ipv4_range_to_cidrs(base, int(val)):
                        key = (net, plen)
                        if key in v4:
                            dup += 1
                        else:
                            v4[key] = cc
                        n4 += 1
                elif typ == "ipv6":
                    plen = int(val)
                    if not 0 < plen <= 128:
                        continue
                    ip = int(ipaddress.IPv6Address(start))
                    shift = 128 - plen
                    net = (ip >> shift) << shift
                    hi = (net >> 64) & 0xFFFFFFFFFFFFFFFF
                    lo = net & 0xFFFFFFFFFFFFFFFF
                    key = (hi, lo, plen)
                    if key in v6:
                        dup += 1
                    else:
                        v6[key] = cc
                    n6 += 1
            except (ValueError, ipaddress.AddressValueError):
                continue
        per_rir[name] = (n4, n6)
        print(f"{name}: ipv4 cidrs={n4} ipv6 nets={n6}")
    print(f"unique v4={len(v4)} v6={len(v6)} dup_keys_skipped={dup}")
    return v4, v6


def write_dat(v4, v6, out_path):
    countries = sorted({c for c in v4.values()} | {c for c in v6.values()})
    cidx = {c: i for i, c in enumerate(countries)}
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "wb") as f:
        f.write(b"GEO1")
        f.write(struct.pack(">I", len(v4)))
        for (net, plen) in sorted(v4):
            f.write(struct.pack(">IBH", net, plen, cidx[v4[(net, plen)]]))
        f.write(struct.pack(">I", len(v6)))
        for (hi, lo, plen) in sorted(v6):
            f.write(struct.pack(">QQBH", hi, lo, plen, cidx[v6[(hi, lo, plen)]]))
        f.write(struct.pack(">H", len(countries)))
        for c in countries:
            f.write(c.encode("ascii"))
    size = os.path.getsize(out_path)
    print(f"wrote {out_path} ({size} bytes, {len(countries)} countries)")
    return countries


def self_check(v4, v6, countries):
    cset = set(countries)

    def lookup_v4(ip):
        n = int(ipaddress.IPv4Address(ip))
        for plen in range(32, -1, -1):
            mask = (0xFFFFFFFF << (32 - plen)) & 0xFFFFFFFF if plen else 0
            if (n & mask, plen) in v4:
                return v4[(n & mask, plen)]
        return None

    for probe in ["8.8.8.8", "1.1.1.1", "192.250.228.44", "185.22.153.221",
                  "95.216.0.1", "51.75.0.1", "77.88.8.8", "9.9.9.9"]:
        print(f"  selfcheck {probe} -> {lookup_v4(probe)}")
    assert "US" in cset and "DE" in cset and "RU" in cset, "big countries missing!"


def main():
    args = [a for a in sys.argv[1:] if a.startswith("--")]
    pos = [a for a in sys.argv[1:] if not a.startswith("--")]
    force = "--force" in args
    max_age_days = 30
    for a in args:
        if a.startswith("--max-age-days="):
            try:
                max_age_days = int(a.split("=", 1)[1])
            except ValueError:
                pass
    input_dir = pos[0] if len(pos) > 0 else DEFAULT_INPUT
    out_path = pos[1] if len(pos) > 1 else DEFAULT_OUT
    if not force and os.path.exists(out_path):
        age_days = (time.time() - os.path.getmtime(out_path)) / 86400.0
        if age_days < max_age_days:
            print(f"geoip.dat is {age_days:.1f} days old (< {max_age_days}) — fresh, skipping refresh")
            return
    fetch_inputs(input_dir)
    v4, v6 = parse(input_dir)
    countries = write_dat(v4, v6, out_path)
    self_check(v4, v6, countries)


if __name__ == "__main__":
    main()
