#!/usr/bin/env python3
"""Upload one screenshot PNG into an appScreenshotSet (Admin key).
Usage: upload_shot.py <setId> <png-path> [fileName]
Reserve -> PUT bytes to uploadOperations -> commit uploaded=true."""
import hashlib
import json
import sys
import time
import urllib.request

import jwt

KEYF = '/Users/apple/private_keys/AuthKey_58GRNURRQK.p8'
ISSUERF = '/Users/apple/private_keys/appconnect_issuer.txt'
API = 'https://api.appstoreconnect.apple.com'


def token():
    import re
    key = open(KEYF).read()
    txt = open(ISSUERF).read()
    issuer = re.search(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', txt).group(0)
    now = int(time.time())
    return jwt.encode({'iss': issuer, 'iat': now, 'exp': now + 1200, 'aud': 'appstoreconnect-v1'},
                      key, algorithm='ES256', headers={'kid': '58GRNURRQK', 'typ': 'JWT'})


def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method,
                                 headers={'Authorization': 'Bearer ' + token(),
                                          'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.status, json.load(r)


def main():
    set_id, png = sys.argv[1], sys.argv[2]
    name = sys.argv[3] if len(sys.argv) > 3 else png.split('/')[-1]
    raw = open(png, 'rb').read()
    md5 = hashlib.md5(raw).hexdigest()
    s, res = call('POST', '/v1/appScreenshots', {"data": {
        "type": "appScreenshots",
        "attributes": {"fileName": name, "fileSize": len(raw)},
        "relationships": {"appScreenshotSet": {"data": {"id": set_id, "type": "appScreenshotSets"}}}}})
    assert s in (200, 201), res
    sid = res['data']['id']
    for op in res['data']['attributes'].get('uploadOperations', []):
        rq = urllib.request.Request(op['url'], data=raw, method=op.get('method', 'PUT'),
                                    headers={'Content-Type': 'image/png', 'Content-Length': str(len(raw))})
        with urllib.request.urlopen(rq, timeout=300) as r:
            r.read()
    s2, res2 = call('PATCH', f'/v1/appScreenshots/{sid}', {"data": {
        "id": sid, "type": "appScreenshots",
        "attributes": {"uploaded": True, "sourceFileChecksum": md5}}})
    assert s2 == 200, res2
    print(f'OK {name} -> shot {sid}')


main()
