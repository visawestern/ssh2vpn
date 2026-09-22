#!/bin/zsh
# Pre-submit gate: prove the Release binary contains zero bytes of the
# DEBUG-only agent channel (Guideline 5.6 hygiene).
# Usage: ./agent-audit-release.sh [<path-to-SSH2VPN.app>]
# Exit 0 = clean, 1 = markers found (DO NOT SUBMIT).
# NOTE: no `pipefail` here on purpose: `strings | grep -q` closes the pipe
# on first match, strings dies with SIGPIPE, and pipefail would turn that
# into a failure — silently inverting every check below (false CLEAN).
set -eu
APP="${1:-/Users/apple/Library/Developer/Xcode/DerivedData/SSH2VPN-*/Build/Products/Release-iphoneos/SSH2VPN.app}"
APP=( $~APP )
BIN="$APP[1]/SSH2VPN"
if [[ ! -f "$BIN" ]]; then
  echo "audit: binary not found: $BIN"
  echo "audit: build it first: xcodebuild build -project Iphone/SSH2VPN.xcodeproj -scheme SSH2VPN -destination 'generic/platform=iOS' -configuration Release"
  exit 2
fi
# Debug-channel markers: hard FAIL, no exceptions — these must never
# reach App Review in any build.
MARKERS=(dbg-ctl-v1 DebugCtlServer "agent channel" DBGCTL "/v1/connect" "/v1/selftest" "17831")
# Google official TEST ad units: allowed ONLY while declared (see below).
# Production swap-back is mandatory before real monetization.
TEST_AD_MARKERS=(3940256099942544)
# Declaration file: one test ad unit ID per line. Exists while and only
# while the submitted build intentionally serves Google's labeled test
# creatives (AdMob unverified) AND Review Notes declare it.
DECLARED="Iphone/.admob-test-declared"
FAIL=0
for m in "${MARKERS[@]}"; do
  if strings "$BIN" | grep -qm1 "$m"; then
    echo "audit: MARKER FOUND: $m"
    FAIL=1
  fi
done
for m in "${TEST_AD_MARKERS[@]}"; do
  if strings "$BIN" | grep -qm1 "$m"; then
    if [[ -f "$DECLARED" ]] && grep -q "$m" "$DECLARED"; then
      echo "audit: DECLARED TEST AD UNIT $m (see $DECLARED + Review Notes) — swap to production + resubmit after AdMob verification"
    else
      echo "audit: UNDECLARED TEST AD UNIT: $m"
      FAIL=1
    fi
  fi
done
# Config-level check: Release must not define DEBUG.
if grep -A12 'B00000010000000000000002 /\* Release \*/' Iphone/SSH2VPN.xcodeproj/project.pbxproj | grep -q 'SWIFT_ACTIVE_COMPILATION_CONDITIONS'; then
  echo "audit: Release config defines SWIFT_ACTIVE_COMPILATION_CONDITIONS"
  FAIL=1
fi
if [[ $FAIL == 0 ]]; then echo "audit: CLEAN — no DEBUG channel in Release binary"; fi
exit $FAIL
