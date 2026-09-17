# SSH2VPN Mac — полный порт на macOS (Intel x86_64 + Apple Silicon)

Тот же VPN по тем же технологиям, что на iOS: настоящий **PacketTunnel
NetworkExtension** (utun, весь трафик системы), тот же SSH-релей
(`VPNCore`), те же DNS-пресеты, кастомные DNS, фильтры/блоклисты,
curated-подписки, kill-switch (on-demand), диагностика, бесплатный час
и Unlimited-покупка через StoreKit. Никакого SOCKS-костыля.

`Iphone/` **не тронут** — Mac-таргеты лежат отдельно в `macbookApp/`,
общие исходники подключены в проект **по ссылке** (`../Iphone/...`).

## Состав

```
macbookApp/
  SSH2VPNMac.xcodeproj/      app SSH2VPNMac + system extension PacketTunnelMac
                             (генерируется: ./scripts/gen-project.py)
  Mac/
    SSH2VPNMacApp.swift      AppModel + VPNController + VPNExtensionAPI +
                             TunnelSelfTester — порт Iphone/App/SSH2VPNApp.swift
    RootView.swift           форк: шаринг через NSSharingServicePicker
    DiagnosticsConsoleSidebarView.swift  форк: NSPasteboard + шаринг
    DocsView.swift           форк: NSViewRepresentable (WebKit)
    AddServerChooserView.swift / ImportCredentialsView.swift
                             форки: убраны iOS-only модификаторы
    AdsStub.swift            стаб AdMob/UMP (API 1-в-1, rewarded всегда noFill)
    SystemExtensionGate.swift активация system extension + approve-инструкция
    SystemExtensionMain.swift entry point (.systemextension — executable)
    Info.plist / PacketTunnel-Info.plist / *.entitlements
  scripts/
    gen-project.py           генератор .pbxproj из iOS-проекта (1-в-1 фазы)
    build-unsigned.sh        проверка компиляции без подписи
    build-universal.sh       universal Release (x86_64 + arm64)
```

По ссылке из `../Iphone` (без копий, без изменений): весь `VPNCore`,
`PacketTunnelProvider.swift`, `PacketTunnelPacketLoop.swift`,
`KeychainStore.swift`, `Localization/Copy/CopyDNS`, `OctohideColors`,
`ServerMetadataResolver`, `StoreManager`, `PaywallView`, ассеты, шрифты,
`Docs/*.html`, `InfoPlist.strings`, `StoreKitConfig.storekit`.

## Отличия от iOS (все помечены `MAC`/`MAC-fork` в коде)

- **System extension** вместо appex: macOS 10.15+ грузит packet-tunnel
  только из `Contents/Library/SystemExtensions` (лежит там, проверено
  в собранном бандле). Первый коннект просит активацию;ткущее окно
  System Settings → General → Login Items & Extensions открывается
  один раз — дальше всё как на iOS. Bundle id расширения:
  `com.ssh2vpn.mac.packet-tunnel`.
- **Нет AdMob/UMP/ATT** (SDK не существует на macOS): кнопка rewarded
  скрыта (`canWatchAd=false`), дозаправка квоты — только Unlimited.
  Бесплатный час, StoreKit-покупка/рестор, гейт в расширении — как на iOS.
- `UIApplication` → `NSApplication`, idle-timer — no-op, шаринги —
  `NSSharingServicePicker`, pasteboard — `NSPasteboard`.

## Сборка

```sh
cd macbookApp
./scripts/build-unsigned.sh    # быстрая проверка компиляции (без подписи)
./scripts/build-universal.sh   # universal Release x86_64+arm64 (без подписи)
```

Проверено на Intel-маке: Debug и Release собираются, оба бинаря —
fat `x86_64 arm64`, `.systemextension` лежит в
`Contents/Library/SystemExtensions`, приложение запускается.

## Signing / первый запуск (обязательно)

Без подписи туннель не стартует: системе нужны entitlements
(NetworkExtension, keychain-group, app-group) и provisioned bundle ids
`com.ssh2vpn.mac` + `com.ssh2vpn.mac.packet-tunnel`.

1. Открыть `SSH2VPNMac.xcodeproj` в Xcode (команда уже залогинена).
2. Target SSH2VPNMac и PacketTunnelMac → Signing & Capabilities:
   Team `326TF9BQ3C`, Automatically manage signing. Xcode сам создаст
   Mac App Development profiles под оба bundle id.
3. Run на своём Intel-маке → разрешить system extension в
   System Settings → General → Login Items & Extensions.
4. Connect в приложении (серверы/настройки/фильтры — как на iOS).

Keychain: `com.sshtunnel.shared`-группа та же, что на iOS (тот же Team ID),
поэтому квота/креды лежат в привычном месте связки ключей.

## Регенерация проекта

`.pbxproj` собирается из iOS-проекта, чтобы фазы/зависимости не разъезжались:

```sh
./scripts/gen-project.py
```

После подтягивания изменений из `Iphone/` (новые общие файлы) — прогнать
генератор и проверить `build-unsigned.sh`. Новые **iOS-only API** во вью
потребуют правок в `Mac/`-форках (компилятор покажет).
