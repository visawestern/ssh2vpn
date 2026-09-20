#!/bin/zsh
# Agent device loop — connect → traffic → selftest → disconnect.
# Codifies the proven 20 Sep 2026 run. Phone must run a DEBUG build
# (Release builds contain no agent channel at all).
# No auth: loopback-only + USB-iproxy path (see DebugCtlServer.swift).
# Usage: ./run.sh [label]   (artifacts go to artifacts/agent-run-<ts>-<label>/)
set -euo pipefail
LABEL="${1:-connect}"
TS="$(date +%Y%m%d-%H%M%S)"
D="/Users/apple/projects/vpnfreeforever/artifacts/agent-run-${TS}-${LABEL}"
mkdir -p "$D"
B="http://127.0.0.1:12771"
DEVPORT=17831
iproxy 12771:$DEVPORT >/dev/null 2>&1 &
FWD=$!
trap "kill $FWD 2>/dev/null" EXIT
sleep 2
date "+%H:%M:%S start" | tee "$D/timeline.txt"
curl -s -m 8 "$B/v1/status" -o "$D/00-baseline.json"
echo "baseline: $(python3 -c "import json;print(json.load(open('$D/00-baseline.json'))['connection'])")"
echo "--- POST /connect:"
curl -s -m 8 -X POST "$B/v1/connect"; echo
echo "--- polling:"
for i in $(seq 1 14); do
  sleep 5
  S="$(curl -s -m 8 "$B/v1/status")"
  C="$(echo "$S" | python3 -c "import json,sys;print(json.load(sys.stdin).get('connection','?'))" 2>/dev/null)"
  echo "t+$((i*5))s: $C" | tee -a "$D/timeline.txt"
  echo "$S" > "$D/status-t$((i*5)).json"
  case "$C" in *connected*) break;; *failed*) break;; esac
done
echo "--- POST /selftest:"
curl -s -m 8 -X POST "$B/v1/selftest"; echo
sleep 45
curl -s -m 10 "$B/v1/logs?tail=250" -o "$D/logs-after.json"
curl -s -m 15 "$B/v1/dump" -o "$D/dump.json"
echo "--- POST /disconnect:"
curl -s -m 8 -X POST "$B/v1/disconnect"; echo
sleep 6
curl -s -m 8 "$B/v1/status" | tee "$D/status-final.json" | python3 -c "import json,sys;print('final:',json.load(sys.stdin)['connection'])"
date "+%H:%M:%S end" | tee -a "$D/timeline.txt"
python3 - "$D" <<'EOF'
import json, re, sys
D = sys.argv[1]
blob = open(f"{D}/dump.json").read() + open(f"{D}/logs-after.json").read()
hits = set(re.findall(r'password|privateKey|hostKey', blob))
print("secret-word hits (method labels are OK, values are not):", sorted(hits) or "none")
EOF
