# SSH2VPN — Android (отдельный порт, папка `androidApp`)

Полный порт iOS-клиента на Android. **Та же relay-архитектура, те же технологии:**
системный VPN (`VpnService` вместо `NEPacketTunnelProvider`) → userspace TCP relay →
SSH **`direct-tcpip`** каналы → штатный `sshd` на VPS пользователя.

Серверу нужен **только `sshd` с `AllowTcpForwarding`** — без root, без TUN, без софта.

## Требования

- Android 11+ (API 30) и выше; `minSdk = 24`, `targetSdk = 34`, `compileSdk = 34`
- JDK 17 для сборки (AGP 8.5): `export JAVA_HOME=<jdk-17>`
- Android SDK (platforms; build-tools 34)

## Сборка (проверено: APK собирается)

```sh
cd androidApp
export JAVA_HOME=/Users/apple/.jdks/jdk-21.0.10+7/Contents/Home  # нужен JDK 17+
export ANDROID_HOME=/usr/local/share/android-commandlinetools    # SDK с platforms;android-34
./gradlew :app:assembleDebug
# APK: app/build/outputs/apk/debug/app-debug.apk (~15 МБ, minSdk 24, targetSdk 34)
```

Установка: `adb install -r app/build/outputs/apk/debug/app-debug.apk`,
затем дать VPN-разрешение по запросу. Проверено `aapt dump badging`:
`SshVpnService` с `BIND_VPN_SERVICE`, FGS `specialUse`, биллинг 7.1.1 на месте.

## Что портировано (паритет с iOS)

| iOS | Android |
|---|---|
| `NEPacketTunnelProvider`, utun, includeAllNetworks+enforceRoutes | `SshVpnService : VpnService`, TUN `10.203.113.2/32`, маршруты `0.0.0.0/0` + `::/0`, `allowBypass=false` при Kill Switch |
| TCP relay (`TCPRelayStateMachine`, sequence-aware, window scaling, backpressure, half-close, MSS 1400) | `core/TcpRelay.kt` — та же семантика |
| SSH пул NIOSSH (demand-grown, max 8, soft-cap 9/conn, pacer, idle-shrink, keepalive 15с, auto-heal, rekey-учёт) | `ssh/SshPool.kt` на JSch `direct-tcpip` (пул/пейсер/шринк/keepalive/heal — те же числа) |
| Pre-flight probe (throwaway `direct-tcpip` к 8.8.8.8:53) | `connectFirst()` + `probeForwarding()` |
| DNS relay: локальные правила → TTL-кэш (cap 300с) → upstream по TCP через `direct-tcpip` | `vpn/DnsRelay.kt` |
| DNS: custom ИЛИ 19 пресетов (взаимоисключающе) + правила block/override | `ScreenSettings`, `core/DnsPresets.kt` (те же 19), `core/DnsFilter.kt` |
| `ServerProfile`, extension-owned store, дедуп, host-key pinning | `ServerStore` (DataStore + EncryptedSharedPreferences), пиннинг в `HostKeyPinning.kt` |
| Ed25519 (unencrypted), password | `SshKeyParser.kt` (тот же отказ для encrypted/других алгоритмов) |
| `QuotaLedger`: 1ч first-use +3ч/rewarded, кулдаун 1ч, cap 12ч, Unlimited; enforcement в расширении | `QuotaStore`, enforcement в `SshVpnService.bringUp()` |
| AdMob rewarded только при выключенном VPN, UMP→start | `AdsManager` |
| Play/AppStore покупка Unlimited $9.99 lifetime, restore | `StoreManager` (product id `unlimited`) |
| Диагностика (фазы, счётчики, last error), консоль с экспортом | `ScreenDiagnostics`, `ScreenConsole` |
| IPv4-only (v6 дроп), UDP только DNS:53 | те же счётчики `v6Dropped`/`udpDropped` |

## Паритет ограничений (как в iOS)

IPv4-only, произвольный UDP (кроме DNS) дропается, зашифрованные SSH-ключи
не поддерживаются (явная ошибка), Always-on VPN — через системные настройки Android.

## Локализация

iOS — 17 языков. Здесь каркас + `en`/`ru` (`values/strings.xml`); остальные
13 добавляются копированием `strings.xml` в `values-<код>/` с теми же ключами.

## Структура

```
androidApp/
├── settings.gradle.kts / build.gradle.kts / gradle.properties
├── gradle/wrapper/gradle-wrapper.properties
├── app/build.gradle.kts / proguard-rules.pro
├── app/src/main/AndroidManifest.xml
└── app/src/main/java/com/ssh2vpn/android/
    ├── core/   IpPacket.kt TcpRelay.kt TcpSequence.kt DnsFilter.kt DnsPresets.kt DnsCache.kt
    ├── ssh/    SshPool.kt HostKeyPinning.kt SshKeyParser.kt
    ├── vpn/    SshVpnService.kt VpnController.kt DnsRelay.kt
    ├── data/   Models.kt ServerStore.kt Stores.kt ConsoleLog.kt
    ├── billing/StoreManager.kt
    ├── ads/AdsManager.kt
    ├── ui/     AppViewModel.kt UiConnect.kt UiServers.kt UiSettings.kt
    ├── MainActivity.kt  SSH2VPNApp.kt
```

Папка `androidApp/` полностью независима: iOS (`Iphone/`) и macOS (`macbookApp/`) не тронуты.

## Паритет с iOS

Дотошная сверка — `PARITY.md` (60 пунктов: ✅24 / 🟡22 / 🔴14 + план добора).
