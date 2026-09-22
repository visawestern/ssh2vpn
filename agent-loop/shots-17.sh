#!/bin/zsh
# 17-locale PROTECTED screenshots with a human shutter.
# The agent drives language + tunnel via the DEBUG channel; the operator
# presses the device screenshot buttons during each HOLD window.
# Resumable: languages with a finished 01-connect shot are skipped.
# Usage: ./shots-17.sh [outdir]
# NOTE: keep this Mac awake; iPhone stays on the Connect tab, tunnel down
# between shots. Restores language to `en` at the end (change LAST if needed).
set -u
OUT="${1:-/Users/apple/projects/vpnfreeforever/artifacts/app-store-screenshots/lang-protected}"
B="http://127.0.0.1:12771"
LANGS=(en es de fr it pt-BR ja zh-Hans ko ar hi th tr pl nl vi ru)
HOLD=22
COOLDOWN=70
mkdir -p "$OUT"
iproxy 12771:17831 >/dev/null 2>&1 &
FWD=$!
trap "kill $FWD 2>/dev/null" EXIT
sleep 2
for L in "${LANGS[@]}"; do
  if [[ -f "$OUT/$L.done" ]]; then echo "== $L: skip (done)"; continue; fi
  echo "== $L: language..."
  curl -s -m 8 -X POST "$B/v1/language" -d "{\"code\":\"$L\"}" > /dev/null
  sleep 3
  echo "== $L: connect..."
  curl -s -m 8 -X POST "$B/v1/connect" > /dev/null
  for i in $(seq 1 8); do
    sleep 5
    C=$(curl -s -m 8 "$B/v1/status" | python3 -c "import json,sys;print(json.load(sys.stdin).get('connection','?'))" 2>/dev/null)
    [[ "$C" == *connected* || "$C" == *failed* ]] && break
  done
  echo "== $L: state=$C — SHOOT NOW (hold ${HOLD}s)"
  sleep $HOLD
  curl -s -m 8 -X POST "$B/v1/disconnect" > /dev/null
  touch "$OUT/$L.done"
  echo "== $L: done, cooldown ${COOLDOWN}s (rate limiter)"
  sleep $COOLDOWN
done
curl -s -m 8 -X POST "$B/v1/language" -d '{"code":"en"}' > /dev/null
echo "ALL DONE -> $OUT (pair each shot with its language; letterbox step is separate)"
