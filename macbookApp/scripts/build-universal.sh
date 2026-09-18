#!/bin/sh
# Universal Release (Intel x86_64 + Apple Silicon arm64), С подписью
# (Automatic, команда уже настроена в проекте — см. README, раздел Signing).
# Быстрая проверка компиляции без подписи: ./scripts/build-unsigned.sh
set -eu
cd "$(dirname "$0")/.."
xcodebuild -project SSH2VPNMac.xcodeproj -scheme SSH2VPNMac \
  -configuration Release -destination 'platform=macOS' \
  ONLY_ACTIVE_ARCH=NO ARCHS="arm64 x86_64" \
  -allowProvisioningUpdates build
PROD=$(ls -d ~/Library/Developer/Xcode/DerivedData/SSH2VPNMac-*/Build/Products/Release/ | head -n 1)
lipo -info "$PROD/SSH2VPNMac.app/Contents/MacOS/SSH2VPNMac"
lipo -info "$PROD/SSH2VPNMac.app/Contents/Library/SystemExtensions/com.ssh2vpn.macos.packet-tunnel.systemextension/Contents/MacOS/PacketTunnelMac"
echo "APP: $PROD/SSH2VPNMac.app"
# System extension активируется ТОЛЬКО из /Applications — ставим туда
# (иначе "Extension not found in App bundle"). В корень репо кладём ZIP,
# а не распакованный .app: дубли bundle id путают LaunchServices/sysextd
# и ломают активацию. DerivedData-копию разрегистрируем по той же причине.
rm -rf /Applications/SSH2VPNMac.app
cp -R "$PROD/SSH2VPNMac.app" /Applications/SSH2VPNMac.app
rm -f ../SSH2VPNMac.app.zip
ditto -c -k --sequesterRsrc --keepParent "$PROD/SSH2VPNMac.app" ../SSH2VPNMac.app.zip
codesign --verify --deep /Applications/SSH2VPNMac.app
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister
"$LSREG" -u "$PROD/SSH2VPNMac.app" >/dev/null 2>&1 || true
"$LSREG" -f /Applications/SSH2VPNMac.app >/dev/null 2>&1 || true
echo "INSTALLED: /Applications/SSH2VPNMac.app + ../SSH2VPNMac.app.zip"
