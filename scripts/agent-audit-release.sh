#!/bin/zsh
# Pre-submit gate: prove the Release binary contains zero bytes of the
# DEBUG-only agent channel (Guideline 5.6 hygiene).
# Usage: ./agent-audit-release.sh [<path-to-SSH2VPN.app>]
# Exit 0 = clean, 1 = markers found (DO NOT SUBMIT).
set -euo pipefail
APP="${1:-/Users/apple/Library/Developer/Xcode/DerivedData/SSH2VPN-*/Build/Products/Release-iphoneos/SSH2VPN.app}"
APP=( $~APP )
BIN="$APP[1]/SSH2VPN"
if [[ ! -f "$BIN" ]]; then
  echo "audit: binary not found: $BIN"
  echo "audit: build it first: xcodebuild build -project Iphone/SSH2VPN.xcodeproj -scheme SSH2VPN -destination 'generic/platform=iOS' -configuration Release"
  exit 2
fi
MARKERS=(dbg-ctl-v1 DebugCtlServer "agent channel" DBGCTL "/v1/connect" "/v1/selftest" "17831" 3940256099942544)
FAIL=0
for m in "${MARKERS[@]}"; do
  if strings "$BIN" | grep -qm1 "$m"; then
    echo "audit: MARKER FOUND: $m"
    FAIL=1
  fi
done
# Config-level check: Release must not define DEBUG.
if grep -A12 'B00000010000000000000002 /\* Release \*/' Iphone/SSH2VPN.xcodeproj/project.pbxproj | grep -q 'SWIFT_ACTIVE_COMPILATION_CONDITIONS'; then
  echo "audit: Release config defines SWIFT_ACTIVE_COMPILATION_CONDITIONS"
  FAIL=1
fi
if [[ $FAIL == 0 ]]; then echo "audit: CLEAN — no DEBUG channel in Release binary"; fi
exit $FAIL
