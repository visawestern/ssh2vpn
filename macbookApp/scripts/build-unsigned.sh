#!/bin/sh
# Проверка компиляции Mac-порта без подписи (ловит ошибки Swift/линковки).
# Полноценный запуск туннеля требует подписи (см. README) — её делает Xcode.
set -eu
cd "$(dirname "$0")/.."
xcodebuild -project SSH2VPNMac.xcodeproj -scheme SSH2VPNMac \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
