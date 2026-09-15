"""Offline proof: score our SYNs with zardaxt's OWN functions and database.

Builds two packets — today's pristine Ubuntu SYN and the same SYN after
masquerade_packet() — parses them into fingerprints exactly the way
src/zardaxt.py records them, and runs src/fingerprint.py's score_fp against
the real database/newCleaned.json:

  python3 verify_score.py

If scikit-learn + the trained relay model are available, it also runs the
real MismatchModel.predict (SYN + iPhone User-Agent -> relay probability),
i.e. the exact verdict the detector serves. Needs network (DB download).
"""
import json
import os
import struct
import sys
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from synmasq import masquerade_packet  # noqa: E402

DB_URL = ("https://raw.githubusercontent.com/NikolaiT/zardaxt"
          "/master/database/newCleaned.json")
MODEL_URL = ("https://raw.githubusercontent.com/NikolaiT/zardaxt"
             "/master/models/tcpip_mismatch.joblib")
IPHONE_UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) "
             "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 "
             "Mobile/15E148 Safari/604.1")


# ---- zardaxt src/fingerprint.py, verbatim logic --------------------------------
def near_ttl(ip_ttl):
    if ip_ttl is None:
        return -1
    if ip_ttl <= 32:
        return 32
    if ip_ttl <= 64:
        return 64
    if ip_ttl <= 128:
        return 128
    return 255


def normalize_fp(fp):
    n = dict(fp)
    n['ip_ttl'] = near_ttl(fp.get('ip_ttl'))
    n['ip_id'] = 0 if fp.get('ip_id') == 0 else 1
    n['tcp_timestamp'] = 0 if fp.get('tcp_timestamp') in ('', None) else 1
    n['tcp_timestamp_echo_reply'] = 0 if fp.get('tcp_timestamp_echo_reply') in ('', None) else 1
    return n


def score_fp(fp, db, db_count):
    totals = {os_name: 0.0 for os_name in db_count}
    for e in db:
        s = 0.0
        s += 1.5 if e['ip_id'] == fp['ip_id'] else 0
        s += 0.25 if e['ip_tos'] == fp['ip_tos'] else 0
        s += 2.5 if e['ip_total_length'] == fp['ip_total_length'] else 0
        s += 2 if e['ip_ttl'] == fp['ip_ttl'] else 0
        s += 2.5 if e['tcp_off'] == fp['tcp_off'] else 0
        s += 2 if e['tcp_timestamp_echo_reply'] == fp['tcp_timestamp_echo_reply'] else 0
        s += 2 if e['tcp_window_scaling'] == fp['tcp_window_scaling'] else 0
        s += 2 if e['tcp_window_size'] == fp['tcp_window_size'] else 0
        s += 0.25 if e['tcp_flags'] == fp['tcp_flags'] else 0
        s += 1.5 if e['tcp_mss'] == fp['tcp_mss'] else 0
        if e['tcp_options'] == fp['tcp_options']:
            s += 4
        elif e['tcp_options_ordered'] == fp['tcp_options_ordered']:
            s += 2.5
        totals[e['os']] += s
    return {k: round(totals[k] / db_count[k], 2) for k in totals}


# ---- packet -> fingerprint, the way zardaxt.py records it ----------------------
def decode_options(opts):
    out, ts, tsecr, mss, ws = '', '', '', 0, None
    i = 0
    while i < len(opts):
        kind = opts[i]
        if kind == 0:
            out += 'E,'
            i += 1
        elif kind == 1:
            out += 'N,'
            i += 1
        else:
            if i + 1 >= len(opts):
                break
            ln = opts[i + 1]
            if ln < 2 or i + ln > len(opts):
                break
            val = opts[i + 2:i + ln]
            if kind == 2:
                mss = struct.unpack('!H', val)[0]
                out += 'M%d,' % mss
            elif kind == 3:
                ws = val[0]
                out += 'W%d,' % ws
            elif kind == 4:
                out += 'S,'
            elif kind == 8:
                out += 'T,'
                ts = struct.unpack('!I', val[0:4])[0]
                tsecr = struct.unpack('!I', val[4:8])[0]
            else:
                out += 'U%d,' % kind
            i += ln
    return out, ts, tsecr, mss, ws


def fp_from_packet(pkt, received_ttl):
    ihl = (pkt[0] & 0x0F) * 4
    total, ip_id, frag, ttl, proto = struct.unpack('!HHHBB', pkt[2:10])
    tos = pkt[1]
    tcp = pkt[ihl:total]
    off = tcp[12] >> 4
    flags = tcp[13]
    win = struct.unpack('!H', tcp[14:16])[0]
    opts = tcp[20:(off * 4)]
    optstr, ts, tsecr, mss, ws = decode_options(opts)
    return {
        'tcp_options': optstr,
        'tcp_options_ordered': ''.join(t[0] for t in optstr.split(',') if t),
        'ip_total_length': total,
        'tcp_off': off,
        'tcp_window_scaling': ws,
        'tcp_window_size': win,
        'ip_ttl': received_ttl,
        'ip_id': ip_id,
        'tcp_timestamp': ts,
        'tcp_timestamp_echo_reply': tsecr if tsecr else '',
        'tcp_mss': mss,
        'tcp_flags': flags,
        'ip_tos': tos,
        'ip_df': 1 if frag & 0x4000 else 0,
    }


def make_ubuntu_syn():
    ip = struct.pack('!BBHHHBBH4s4s', 0x45, 0, 60, 0x1234, 0x4000,
                     64, 6, 0, bytes([192, 250, 228, 44]), bytes([93, 184, 216, 34]))
    opts = (b'\x02\x04\x05\xb4' + b'\x04\x02' + b'\x08\x0a'
            + struct.pack('!II', 0x11223344, 0) + b'\x01' + b'\x03\x03\x07')
    tcp = struct.pack('!HHIIBBHHH', 45678, 443, 0xA1B2C3D4, 0,
                      (10 << 4), 0x02, 64240, 0, 0) + opts
    return ip + tcp


def _num(value, default=-1.0):
    return float(default if value is None or value == '' else value)


def feature_vector(fp, os_name, vocabs):
    """zardaxt src/fingerprint.py, verbatim logic (categorical fallback 'other')."""
    ordered = fp.get('tcp_options_ordered') or ''.join(
        t[0] for t in (fp.get('tcp_options') or '').split(',') if t)
    row = [
        float(near_ttl(fp.get('ip_ttl'))),
        1.0 if fp.get('ip_id') == 0 else 0.0,
        _num(fp.get('ip_tos')),
        _num(fp.get('ip_total_length')),
        _num(fp.get('tcp_off')),
        _num(fp.get('tcp_window_scaling')),
        _num(fp.get('tcp_window_size')),
        _num(fp.get('tcp_mss')),
        _num(fp.get('tcp_flags')),
        0.0 if fp.get('tcp_timestamp') in ('', None) else 1.0,
        _num(fp.get('ip_df')),
    ]
    for name, value in (('tcp_options', fp.get('tcp_options') or ''),
                        ('tcp_options_ordered', ordered),
                        ('ua_os', os_name or 'unknown')):
        vocab = vocabs[name]
        row.append(float(vocab.get(value, vocab['other'])))
    return row


def try_model(fp):
    """The real relay verdict, if sklearn + artifact are available."""
    try:
        import joblib
    except ImportError:
        return 'sklearn/joblib missing: pip install scikit-learn joblib'
    try:
        url = urllib.request.urlopen(MODEL_URL, timeout=60)
        with open('/tmp/zardaxt_model.joblib', 'wb') as f:
            f.write(url.read())
        a = joblib.load('/tmp/zardaxt_model.joblib')
        row = feature_vector(fp, 'iOS', a['vocabs'])
        proba = float(a['model'].predict_proba([row])[0][1])
        return {'probability': round(proba, 4), 'threshold': a['threshold'],
                'flagged': proba >= a['threshold'], 'ua_os': 'iOS'}
    except Exception as e:
        return 'model unavailable: %r' % (e,)


def main():
    print('downloading zardaxt database...', flush=True)
    db = json.load(urllib.request.urlopen(DB_URL, timeout=60))
    counts = {}
    for e in db:
        counts[e['os']] = counts.get(e['os'], 0) + 1
    print('database: %d fingerprints %s' % (len(db), counts))

    pristine = make_ubuntu_syn()
    masked = masquerade_packet(pristine)
    assert masked is not None and masked != pristine

    # As-received TTL at a site a few hops away (both bucket to 64).
    for label, pkt in (('PRISTINE Ubuntu SYN (today)', pristine),
                       ('MASQUERADED SYN (iOS template)', masked)):
        fp = normalize_fp(fp_from_packet(pkt, 58))
        scores = score_fp(fp, db, counts)
        best = max(scores, key=scores.get)
        print('\n%s\n  fp=%s\n  scores=%s\n  => detected OS: %s (UA claims iOS)'
              % (label, {k: fp[k] for k in
                         ('tcp_options', 'ip_total_length', 'tcp_off',
                          'tcp_window_scaling', 'tcp_window_size', 'ip_ttl',
                          'ip_id', 'tcp_mss', 'tcp_flags', 'ip_tos')},
                 scores, best))
        print('  relay model:', try_model(fp_from_packet(pkt, 58)))


if __name__ == '__main__':
    main()
