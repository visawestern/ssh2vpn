"""SYN masquerader: our egress TCP SYNs wear the iOS fingerprint.

Problem: a site running passive TCP/IP fingerprinting (zardaxt and its
commercial front proxydetect.live) scores ONLY the SYN packet. Our relay
terminates the phone's TCP at the tunnel and the VPS kernel opens a fresh
connection to the site — so the site sees an Ubuntu SYN next to an iPhone
User-Agent: "Mismatch with User-Agent (possible proxy)".

Fix: rewrite our OUTPUT SYNs to the dominant iOS fingerprint from zardaxt's
own database (213 iOS samples), before they leave the VPS:

  options  M1400,N,W6,N,N,T,S,E,E,  (MNWNNTSEE, 24 bytes -> off 11, len 64)
  window 65535, wscale 6, mss 1400, flags 194 (SYN+ECE+CWR),
  timestamp option present (kernel TSval bytes preserved untouched),
  ip_id 0, ttl/tos/DF kept (already iOS-equal: 64/0/DF=1).

Only the SYN is fingerprinted, so NOTHING else changes: seq/ack/ports/
addresses/payload pass through, checksums are recomputed, and the kernel
never notices (it doesn't re-read its own SYN). The peer only observes a
smaller MSS (1400) and ECN-capable flags — both harmless.

Safety: pure function on bytes; ANY anomaly (short packet, IP options,
non-TCP, not a pure SYN) returns None = accept unmodified (fail-open, never
breaks traffic). Only SYN without ACK is ever rewritten — SYN-ACKs,
retransmits-with-payload shape and everything inbound are untouched.

Deployment (needs root on the VPS): install.sh adds
  iptables -t mangle -A OUTPUT -p tcp --syn -j NFQUEUE --queue-num 0
  ip6tables -t mangle -A OUTPUT -p tcp --syn -j NFQUEUE --queue-num 0
and runs this file as a systemd service. What this does NOT fix: IP/ASN
reputation verdicts (datacenter IP stays datacenter) — that is a different
layer from the TCP fingerprint.
"""

import struct
import sys

# Dominant iOS values from zardaxt database/newCleaned.json (mode of samples).
IOS_MSS = 1400
IOS_WSCALE = 6
IOS_WINDOW = 65535
IOS_TCP_FLAGS = 0xC2  # SYN | ECE | CWR = 194
IOS_TCP_HEADER_LEN = 44  # 20 base + 24 options -> data offset 11
IOS_TOTAL_LEN = 64  # 20 IP + 44 TCP, no payload

_TCP_SYN = 0x02
_TCP_ACK = 0x10


def _checksum(data: bytes) -> int:
    if len(data) % 2:
        data += b"\x00"
    s = sum(struct.unpack("!%dH" % (len(data) // 2), data))
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return s ^ 0xFFFF


def _tcp_checksum_v4(src: bytes, dst: bytes, tcp: bytes) -> int:
    return _checksum(src + dst + struct.pack("!BBH", 0, 6, len(tcp)) + tcp)


def _tcp_checksum_v6(src: bytes, dst: bytes, tcp: bytes) -> int:
    return _checksum(src + dst + struct.pack("!I3xB", len(tcp), 6) + tcp)


def _find_timestamps(opts: bytes):
    """(tsval, tsecr) from a TCP options blob; (0, 0) when absent."""
    i = 0
    while i < len(opts):
        kind = opts[i]
        if kind == 0:  # EOL
            break
        if kind == 1:  # NOP
            i += 1
            continue
        if i + 1 >= len(opts):
            break
        ln = opts[i + 1]
        if ln < 2 or i + ln > len(opts):
            break
        if kind == 8 and ln == 10:  # timestamps
            return struct.unpack("!II", opts[i + 2:i + 10])
        i += ln
    return (0, 0)


def _ios_options(tsval: int, tsecr: int) -> bytes:
    """24-byte iOS option block. TS values are the kernel's own bytes —
    only kinds/order/MSS/WS are normalized, so kernel RTTM keeps working."""
    return (struct.pack("!BBH", 2, 4, IOS_MSS)      # MSS 1400
            + b"\x01"                                # NOP
            + struct.pack("!BBB", 3, 3, IOS_WSCALE)  # WS 6
            + b"\x01\x01"                            # NOP NOP
            + struct.pack("!BBII", 8, 10, tsval, tsecr)  # TS (values kept)
            + b"\x04\x02"                            # SACK OK
            + b"\x00\x00")                           # EOL EOL


def _rewrite_tcp(tcp: bytes):
    """Rebuild a pure-SYN TCP segment with the iOS template. None on anomaly."""
    if len(tcp) < 20:
        return None
    (sport, dport, seq, ack, off_flags, flags, _win,
     _csum, urg) = struct.unpack("!HHIIBBHHH", tcp[:20])
    if flags & (_TCP_SYN | _TCP_ACK) != _TCP_SYN:
        return None  # not a pure SYN (SYN-ACK, RST, data...)
    hdr_len = (off_flags >> 4) * 4
    if hdr_len < 20 or hdr_len > len(tcp):
        return None
    tsval, tsecr = _find_timestamps(tcp[20:hdr_len])
    payload = tcp[hdr_len:]
    head = struct.pack("!HHIIBBHHH", sport, dport, seq, ack,
                       (11 << 4), IOS_TCP_FLAGS, IOS_WINDOW, 0, urg)
    return head + _ios_options(tsval, tsecr) + payload


def masquerade_packet(pkt: bytes):
    """Rewrite one OUTPUT IP packet's SYN to the iOS template.

    Returns the new packet bytes, or None when the packet must pass through
    untouched (not TCP, not a pure SYN, malformed). Never raises.
    """
    try:
        if len(pkt) < 20:
            return None
        ver = pkt[0] >> 4
        if ver == 4:
            return _masquerade_v4(pkt)
        if ver == 6:
            return _masquerade_v6(pkt)
        return None
    except Exception:
        return None


def _masquerade_v4(pkt: bytes):
    ihl = (pkt[0] & 0x0F) * 4
    if ihl != 20 or len(pkt) < ihl:  # no IP options on kernel SYNs; else bail
        return None
    if pkt[9] != 6:  # not TCP
        return None
    total = struct.unpack("!H", pkt[2:4])[0]
    if total > len(pkt) or total < ihl + 20:
        return None
    new_tcp = _rewrite_tcp(pkt[ihl:total])
    if new_tcp is None:
        return None
    # NOTE: _rewrite_tcp preserves any TCP payload; lengths follow.
    new_tcp = bytearray(new_tcp)
    struct.pack_into("!H", new_tcp, 16,
                     _tcp_checksum_v4(pkt[12:16], pkt[16:20], bytes(new_tcp)))
    new_total = 20 + len(new_tcp)
    ip = bytearray(pkt[:20])
    struct.pack_into("!H", ip, 2, new_total)
    struct.pack_into("!H", ip, 4, 0)  # ip_id 0: 98% of iOS SYNs
    struct.pack_into("!H", ip, 10, 0)
    struct.pack_into("!H", ip, 10, _checksum(bytes(ip[:20])))
    return bytes(ip) + new_tcp + pkt[total:]


def _masquerade_v6(pkt: bytes):
    if len(pkt) < 40:
        return None
    if pkt[6] != 6:  # next header not TCP (no ext headers on kernel SYNs)
        return None
    plen = struct.unpack("!H", pkt[4:6])[0]
    if 40 + plen > len(pkt) or plen < 20:
        return None
    new_tcp = _rewrite_tcp(pkt[40:40 + plen])
    if new_tcp is None:
        return None
    new_tcp = bytearray(new_tcp)
    struct.pack_into("!H", new_tcp, 16,
                     _tcp_checksum_v6(pkt[8:24], pkt[24:40], bytes(new_tcp)))
    out = bytearray(pkt[:40])
    struct.pack_into("!H", out, 4, len(new_tcp))
    # traffic class / flow label / hoplimit / addresses pass through untouched
    return bytes(out) + bytes(new_tcp) + pkt[40 + plen:]


def build_test_ipv6_syn() -> bytes:
    """Loopback-style Ubuntu SYN over IPv6 for the unit test."""
    opts = (b"\x02\x04\x05\xa0" + b"\x04\x02" + b"\x08\x0a"
            + struct.pack("!II", 0xAABBCCDD, 0) + b"\x01" + b"\x03\x03\x07")
    tcp = (struct.pack("!HHIIBBHHH", 45678, 443, 0x01020304, 0,
                       (10 << 4), 0x02, 64240, 0, 0) + opts)
    return (struct.pack("!IHBB16s16s", 0x60000000, len(tcp), 6, 64,
                        bytes.fromhex("fd00" + "00" * 13 + "01"),
                        bytes.fromhex("fd00" + "00" * 13 + "02"))
            + tcp)


def _nfq_callback(nfq_packet):
    try:
        raw = nfq_packet.get_payload()
        new = masquerade_packet(raw)
        if new is not None and new != raw:
            nfq_packet.set_payload(new)
    except Exception:
        pass
    nfq_packet.accept()


def main(queue_num: int = 0) -> int:
    try:
        from netfilterqueue import NetfilterQueue
    except ImportError:
        print("need NetfilterQueue: pip install NetfilterQueue "
              "(+ libnetfilter-queue dev package)", file=sys.stderr)
        return 2
    nfq = NetfilterQueue()
    nfq.bind(queue_num, _nfq_callback)
    print("synmasq: mangling OUTPUT SYNs on queue %d" % queue_num, flush=True)
    nfq.run()
    return 0


if __name__ == "__main__":
    sys.exit(main(int(sys.argv[1]) if len(sys.argv) > 1 else 0))
