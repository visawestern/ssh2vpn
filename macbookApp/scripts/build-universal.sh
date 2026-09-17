#!/bin/sh
# Universal Release (Intel x86_64 + Apple Silicon arm64), без подписи.
# Для распространения подписать в Xcode (README, раздел Signing).
set -eu
cd "$(dirname "$0")/.."
xcodebuild -project SSH2VPNMac.xcodeproj -scheme SSH2VPNMac \
  -configuration Release -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO ARCHS="arm64 x86_64" build
PROD=$(ls -d ~/Library/Developer/Xcode/DerivedData/SSH2VPNMac-*/Build/Products/Release/ | head -n 1)
lipo -info "$PROD/SSH2VPNMac.app/Contents/MacOS/SSH2VPNMac"
lipo -info "$PROD/SSH2VPNMac.app/Contents/Library/SystemExtensions/PacketTunnelMac.systemextension/Contents/MacOS/PacketTunnelMac"
echo "APP: $PROD/SSH2VPNMac.app"
