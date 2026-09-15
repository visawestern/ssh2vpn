"""Golden tests for the SYN masquerader (TDD: written before synmasq.py).

The detector (zardaxt) scores ONLY the SYN packet. Our VPS kernel emits an
Ubuntu SYN while the browser's User-Agent claims iPhone -> "Mismatch with
User-Agent (possible proxy)". The masquerader rewrites our egress SYNs to
the dominant iOS fingerprint from zardaxt's own database (213 iOS samples):

  tcp_options  M1400,N,W6,N,N,T,S,E,E,   (order MNWNNTSEE)
  ip_total_length 64, tcp_off 11, window 65535, wscale 6, mss 1400,
  flags 194 (SYN+ECE+CWR), timestamp present, ttl 64, tos 0, ip_id 0, DF set.

These tests run anywhere (no root, no network): they feed a byte-exact
Ubuntu-kernel-style SYN in and assert a byte-exact iOS-style SYN out.
"""

import os
import struct
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import synmasq
from synmasq import masquerade_packet


def ip_checksum(header: bytes) -> int:
    """Independent checksum implementation for the tests (not shared code)."""
    if len(header) % 2:
        header += b"\x00"
    s = sum(struct.unpack("!%dH" % (len(header) // 2), header))
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return s ^ 0xFFFF


def tcp_checksum(src: bytes, dst: bytes, tcp: bytes) -> int:
    pseudo = src + dst + struct.pack("!BBH", 0, 6, len(tcp))
    return ip_checksum(pseudo + tcp)


def tcp_checksum_v6(src: bytes, dst: bytes, tcp: bytes) -> int:
    pseudo = src + dst + struct.pack("!I3xB", len(tcp), 6)
    return ip_checksum(pseudo + tcp)


def make_ubuntu_syn(*, seq=0xA1B2C3D4, sport=45678, dport=443,
                    tsval=0x11223344, ip_id=0x1234, payload=b""):
    """A byte-exact Ubuntu 6.8 kernel SYN: MSS,SACK,TS,NOP,WS7, win 64240."""
    ip = struct.pack("!BBHHHBBH4s4s",
                     0x45, 0, 20 + 20 + 20 + len(payload), ip_id, 0x4000,
                     64, 6, 0,
                     bytes([192, 250, 228, 44]), bytes([93, 184, 216, 34]))
    opts = (b"\x02\x04\x05\xb4"          # MSS 1460
            + b"\x04\x02"                # SACK OK
            + b"\x08\x0a" + struct.pack("!II", tsval, 0)  # TS
            + b"\x01"                    # NOP
            + b"\x03\x03\x07")           # WS 7
    tcp = struct.pack("!HHIIBBHHH", sport, dport, seq, 0,
                      (10 << 4), 0x02, 64240, 0, 0) + opts + payload
    return ip + tcp


class MasqueradeTests(unittest.TestCase):
    maxDiff = 4096

    def test_ubuntu_syn_becomes_ios_template(self):
        out = masquerade_packet(make_ubuntu_syn())
        self.assertIsNotNone(out, "pure SYN must be rewritten")

        ver_ihl, tos, total, ip_id, frag, ttl, proto = struct.unpack("!BBHHHBB", out[:10])[:7]
        self.assertEqual((ver_ihl, tos, total, ip_id, frag, ttl, proto),
                         (0x45, 0, 64, 0, 0x4000, 64, 6))
        # src/dst untouched
        self.assertEqual(out[12:20], bytes([192, 250, 228, 44, 93, 184, 216, 34]))
        self.assertEqual(ip_checksum(out[:20]), 0, "IP checksum must be valid")

        tcp = out[20:]
        sport, dport, seq, ack, off, flags, win = struct.unpack("!HHIIBBH", tcp[:16])
        self.assertEqual((sport, dport, seq, ack), (45678, 443, 0xA1B2C3D4, 0))
        self.assertEqual((off >> 4, flags, win), (11, 194, 65535))
        self.assertEqual(tcp[18:20], b"\x00\x00")  # urgptr kept zero

        opts = tcp[20:44]
        tsval = struct.unpack("!I", opts[12:16])[0]
        self.assertEqual(tsval, 0x11223344, "kernel TSval must survive (RTTM safety)")
        self.assertEqual(opts[16:20], b"\x00\x00\x00\x00", "TSecr stays zero on SYN")
        # option skeleton: MSS/NOP/WS/NOP/NOP/TS/SACK/EOL/EOL with iOS values
        self.assertEqual(opts[0:4], b"\x02\x04\x05\x78", "MSS 1400")
        self.assertEqual(opts[4:5], b"\x01")
        self.assertEqual(opts[5:8], b"\x03\x03\x06", "WS 6")
        self.assertEqual(opts[8:10], b"\x01\x01")
        self.assertEqual(opts[10:12], b"\x08\x0a")
        self.assertEqual(opts[20:24], b"\x04\x02\x00\x00", "SACK OK + EOL pad")
        self.assertEqual(len(tcp), 44, "no payload in, none out")

        self.assertEqual(
            tcp_checksum(out[12:16], out[16:20], tcp), 0, "TCP checksum must be valid")

    def test_zardaxt_option_string_matches(self):
        """The exact string zardaxt builds from our output must equal the DB mode."""
        out = masquerade_packet(make_ubuntu_syn())
        kinds = []
        i = 20 + 20
        end = 20 + 44
        while i < end:
            kind = out[i]
            if kind == 0:
                kinds.append("E")
                i += 1
            elif kind == 1:
                kinds.append("N")
                i += 1
            elif kind == 2:
                kinds.append("M%d" % struct.unpack("!H", out[i + 2:i + 4])[0])
                i += 4
            elif kind == 3:
                kinds.append("W%d" % out[i + 2])
                i += 3
            elif kind == 4:
                kinds.append("S")
                i += 2
            elif kind == 8:
                kinds.append("T")
                i += 10
            else:
                self.fail("unexpected option kind %d" % kind)
        self.assertEqual(",".join(kinds) + ",", "M1400,N,W6,N,N,T,S,E,E,")
        self.assertEqual("".join(k[0] for k in kinds), "MNWNNTSEE")

    def test_swek_non_syn_untouched(self):
        base = make_ubuntu_syn()
        # Flip to SYN+ACK: must NOT be rewritten (inbound direction anyway).
        synack = bytearray(base)
        synack[20 + 13] = 0x12
        self.assertIsNone(masquerade_packet(bytes(synack)))
        # Plain ACK: untouched.
        ack = bytearray(base)
        ack[20 + 13] = 0x10
        self.assertIsNone(masquerade_packet(bytes(ack)))

    def test_payload_preserved(self):
        out = masquerade_packet(make_ubuntu_syn(payload=b"\xde\xad\xbe\xef"))
        self.assertIsNotNone(out)
        self.assertEqual(out[44 + 20:], b"\xde\xad\xbe\xef")
        ver_ihl, _, total = struct.unpack("!BBH", out[:4])
        self.assertEqual(total, 64 + 4)

    def test_missing_options_get_ios_defaults(self):
        # Kernel with no WS/TS/SACK (hardened sysctl): still iOS-shaped out.
        raw = bytearray(make_ubuntu_syn())
        # shrink TCP to bare MSS-only options: rebuild minimal SYN
        ip = raw[:20]
        tcp = struct.pack("!HHIIBBHHH", 45678, 443, 0xA1B2C3D4, 0,
                          (6 << 4), 0x02, 64240, 0, 0) + b"\x02\x04\x05\xb4"
        pkt = bytes(ip[:2] + struct.pack("!H", 20 + 24) + bytes(ip[4:])) + tcp
        out = masquerade_packet(pkt)
        self.assertIsNotNone(out)
        self.assertEqual(out[20:24], struct.pack("!HH", 45678, 443), "ports kept")
        opts = out[40:64]
        self.assertEqual(opts[0:4], b"\x02\x04\x05\x78")
        self.assertEqual(opts[5:8], b"\x03\x03\x06")
        self.assertEqual(opts[10:12], b"\x08\x0a")

    def test_ipv6_syn_rewritten(self):
        pkt = synmasq.build_test_ipv6_syn()
        out = masquerade_packet(pkt)
        self.assertIsNotNone(out)
        self.assertEqual(out[0] >> 4, 6)
        self.assertEqual(out[6], 6, "next header stays TCP")
        # TCP part: same iOS template
        tcph = 40
        off, flags, win = struct.unpack("!BBH", out[tcph + 12:tcph + 16])
        self.assertEqual((off >> 4, flags, win), (11, 194, 65535))
        opts = out[tcph + 20:tcph + 44]
        self.assertEqual(opts[0:4], b"\x02\x04\x05\x78")
        self.assertEqual(opts[5:8], b"\x03\x03\x06")
        self.assertEqual(out[7], 64, "hoplimit kept")
        plen = struct.unpack("!H", out[4:6])[0]
        self.assertEqual(plen, len(out) - 40, "v6 payload length consistent")
        self.assertEqual(
            tcp_checksum_v6(out[8:24], out[24:40], out[40:]), 0,
            "TCPv6 checksum must be valid")

    def test_truncated_and_foreign_packets_ignored(self):
        self.assertIsNone(masquerade_packet(b"\x45\x00\x00"))
        self.assertIsNone(masquerade_packet(b""))  # empty
        # UDP: untouched
        udp = struct.pack("!BBHHHBBH4s4sHHHH",
                          0x45, 0, 28, 1, 0x4000, 64, 17, 0,
                          bytes([1, 1, 1, 1]), bytes([2, 2, 2, 2]),
                          53, 53, 8, 0)
        self.assertIsNone(masquerade_packet(udp))


if __name__ == "__main__":
    unittest.main()
