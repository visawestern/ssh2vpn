#!/usr/bin/env python3
"""Read-only App Store Connect audit (metadata, versions, IAPs, screenshots).
Uses local .p8 API key (Key ID from filename); key material never printed.
Usage: asc-audit.py <issuer-id> [outdir]
Writes raw JSON to outdir for offline diffing. No writes to Apple whatsoever.
"""
import json
import os
import sys
import time
import urllib.request

API = "https://api.appstoreconnect.apple.com"
KEY_ID = "64X33J73MF"
P8 = "/Users/apple/projects/vpnfreeforever/AuthKey_64X33J73MF.p8"

import jwt  # pyjwt

def token(issuer):
    with open(P8) as f:
        key = f.read()
    now = int(time.time())
    return jwt.encode(
        {"iss": issuer, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
        key, algorithm="ES256", headers={"kid": KEY_ID, "typ": "JWT"},
    )

def get(tok, path, params=""):
    req = urllib.request.Request(
        API + path + params,
        headers={"Authorization": "Bearer " + tok, "Accept": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)

def main():
    issuer, out = sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "/tmp/asc-audit"
    os.makedirs(out, exist_ok=True)
    tok = token(issuer)
    dump = {}
    apps = get(tok, "/v1/apps", '?filter[bundleId]=com.ssh2vpn.app&fields[apps]=name,bundleId,primaryLocale')
    dump["apps"] = apps
    app_id = apps["data"][0]["id"]
    print("app:", app_id, apps["data"][0]["attributes"])
    vers = get(tok, f"/v1/apps/{app_id}/appStoreVersions", "?limit=200&fields[appStoreVersions]=versionString,platform,appStoreState,copyright,usesIdfa,releaseType")
    dump["versions"] = vers
    for v in vers["data"]:
        a = v["attributes"]
        print(f"version {a.get('versionString')} {a.get('platform')} state={a.get('appStoreState')}")
    open(f"{out}/apps-versions.json", "w").write(json.dumps(dump, indent=1, ensure_ascii=False))
    # IAPs (delete needs App Manager role — this key is read-only for IAPs)
    iaps = get(tok, f"/v1/apps/{app_id}/inAppPurchases", "?limit=200")
    summ = []
    for p in iaps.get("data", []):
        a = p["attributes"]
        print(f"IAP {a.get('productId')} ref={a.get('referenceName')!r} state={a.get('state')}")
        summ.append({"id": p["id"], "attributes": a})
    open(f"{out}/iaps.json", "w").write(json.dumps(summ, indent=1, ensure_ascii=False))
    # Version localizations (all locales, full text)
    for v in vers["data"]:
        va = v["attributes"]
        locs = get(tok, f"/v1/appStoreVersions/{v['id']}/appStoreVersionLocalizations", "?limit=200")
        vd = {"version": va.get("versionString"), "state": va.get("appStoreState"), "locales": {}}
        for loc in locs.get("data", []):
            la = loc["attributes"]
            vd["locales"][la.get("locale")] = {
                k: la.get(k) for k in ("name", "subtitle", "keywords", "description",
                                       "promotionalText", "whatsNew", "marketingUrl",
                                       "supportUrl", "privacyPolicyUrl", "privacyPolicyText")
            }
        open(f"{out}/version-{va.get('versionString')}-{v['id']}.json", "w").write(
            json.dumps(vd, indent=1, ensure_ascii=False))
        print(f"version {va.get('versionString')}: {len(vd['locales'])} locales saved")
    # Screenshot inventory for the rejected version
    rej = [v for v in vers["data"] if v["attributes"].get("appStoreState") == "REJECTED"]
    if rej:
        v = rej[0]
        locs = get(tok, f"/v1/appStoreVersions/{v['id']}/appStoreVersionLocalizations", "?limit=200")
        inv = {}
        for loc in locs.get("data", []):
            sets = get(tok, f"/v1/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets", "?limit=100")
            inv[loc["attributes"].get("locale")] = [
                {"setId": s["id"], "displayType": s["attributes"].get("screenshotDisplayType")}
                for s in sets.get("data", [])
            ]
        open(f"{out}/screenshots-inventory.json", "w").write(json.dumps(inv, indent=1, ensure_ascii=False))
        total = sum(len(s) for s in inv.values())
        print(f"screenshot sets total: {total} across {len(inv)} locales")
    print("saved ->", out)

main()
