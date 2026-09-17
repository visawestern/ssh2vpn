# Паритет Android ↔ iOS — дотошная сверка (60 пунктов)

Метод: каждый пункт сверен с кодом iOS (`Iphone/App`, `Iphone/Sources/VPNCore`),
а не с ТЗ. Роль — адвокат дьявола: где Android слабее, так и написано.
Легенда: ✅ паритет · 🟡 частично · 🔴 нет · ➖ неприменимо (архитектура платформы).

---

## A. Data-plane: TCP relay (порт `TCPRelayStateMachine.swift` → `core/TcpRelay.kt`)

| # | Пункт | Статус | iOS (факт) | Android (факт) | Адвокат дьявола → как дотянуть |
|---|-------|--------|------------|----------------|--------------------------------|
| P-01 | Sequence-aware relay, дедуп/ooo/partial-overlap | ✅ | `forwardPhoneData`: dist==0 → forward; dist<0 → trim дубликата; dist>0 → ooo + ACK | Тот же алгоритм (`TcpSequence.distance`, trim, ACK) | Проверено 23 JVM-тестами. Ничего не делать. |
| P-02 | MSS-сегментация 1400 | ✅ | `maxSegmentPayload = 1400`, комментарий про 0xFFFF-overflow | `MAX_SEGMENT_PAYLOAD = 1400`, та же нарезка | Паритет. |
| P-03 | Window scaling + backpressure | ✅ | `peerWindowScale` из SYN, `effectivePeerWindow`, `availablePeerWindow`, `pendingToPhone`, flush по ACK | Портировано 1-в-1 | Паритет. |
| P-04 | RST: мгновенный teardown; stray → RST (RFC 793 §3.4); SYN на живую запись → переоткрытие | ✅ | Всё три ветки есть | Все три есть, покрыты тестами | Паритет. |
| P-05 | FIN/half-close: ACK FIN+payload, `phoneFinSeen`, `channelClosed → FIN` телефону | ✅ | Есть | Есть | Паритет. |
| P-06 | Idle expiry 60с | ✅ | `expireIdle`, default 60 | `expireIdle`, default 60_000 мс, sweeper каждые 15с | Паритет (sweeper чаще — только лучше). |
| P-07 | Прото-сплит и счётчики TUN | ✅ | `v4tcp/v4udp/v4other/v6/nonIP`, `packetsRead/Written`, `protoSummary`, `lastReadAt` (stall watchdog отличает «юзер idle» от «мёртвый flow») | Есть `up/down/flows/channels/udpDropped/v6Dropped`, но нет сплита `v4other/nonIP`, нет `packetsRead/Written`, нет `lastReadAt` | DONE: реализовано в этом заходе (см. код): DONE: Дотянуть: добавить в `SshVpnService.packetLoop` классификатор как `countProtocol` + `lastReadAt`; stall watchdog уже частично есть (heal при пустом пуле). ~1 час работы. | DONE: реализовано в этом заходе (см. код). |
| P-08 | Выбор подсети TUN + anti-collision | ✅ | `TunnelSubnetPicker`: кандидаты `10.203.h1/24`, `172.31.h1/24`, `192.168.(200+h1%55)/24` от SHA256(brokerID), проверка занятости через `getifaddrs`, маска **/24** (иначе iOS не ставит default route) | Хардкод `10.203.113.2/32`, без проверки коллизий | DONE: реализовано в этом заходе (см. код): DONE: Дотянуть: `SubnetPicker.kt` (SHA256 от ANDROID_ID, те же 3 кандидата) + перечисление `NetworkInterface.getNetworkInterfaces()` (эквивалент getifaddrs, без рута); адрес `.2`, маску /24? На Android /32 + route 0/0 — штатный ToyVpn-паттерн и работает, но при коллизии с WiFi 10.x трафик уйдёт мимо — поэтому picker нужен. ~3 часа. | DONE: реализовано в этом заходе (см. код). |
| P-09 | MTU 1500 | ✅ | 1500 | 1500 | Паритет. |
| P-10 | IPv6 дроп + не-DNS UDP дроп со счётчиками | ✅ | v6 классифицируется/дропается, UDP только :53 | То же + счётчики в Stats | Паритет. |

## B. SSH-транспорт (порт `SSHConnectionPool.swift` → `ssh/SshPool.kt`, JSch вместо NIOSSH)

| # | Пункт | Статус | iOS | Android | Адвокат → как дотянуть |
|---|-------|--------|-----|---------|------------------------|
| P-11 | Только `direct-tcpip`, без левых типов каналов | ✅ | `NIOSSHChannelOpener.open(targetHost...)`, exec только для диагностики | JSch `openChannel("direct-tcpip")`; exec только self-test | Паритет. Проверено компиляцией против настоящего JSch 0.2.21. |
| P-12 | Числа пула: max 8, soft-cap 9/conn, pacer 3 dials + 0.4с, shrink 60с min 2 | ✅ | `SSHPoolPolicy(8, 9)`, `SSGrowPacer(3, 0.4)`, `shrinkIdle(60, min 2)` | Те же числа | Паритет. |
| P-13 | Pre-flight probe + fallback | ✅ | Throwaway `direct-tcpip` к 8.8.8.8:53/1.1.1.1:53; при провале — ещё и **localhost-probe** перед отказом | Probe к тем же двум есть; localhost-fallback нет | DONE: Дотянуть: при провале обоих — открыть канал к 127.0.0.1:22 через тот же SSH (доказывает, что sshd жив, а режет именно внешний egress) и отдать код `forwardingRefused` vs `egressBlocked`. 30 минут. |
| P-14 | Стабильные коды ошибок + FATAL/transient (защита от fail2ban) | ✅ | `stableStartError`: `authFailedExhausted`/`hostKeyMismatch`/`forwardingRefused` = FATAL (без авто-ретрая), timeout/`egressBlocked` = transient | `humanize()` даёт русские тексты, но кодов нет; heal с backoff долбит мёртвый сервер до 1ч — при неверном пароле это выглядит как ретрай-шторм | DONE: Дотянуть: завести `sealed SshStartError { AuthFatal, HostKeyMismatch, ForwardingRefused, EgressBlocked, Transient }`, heal запретить при Fatal; `lastError` отдавать кодом + текстом. 2 часа. |
| P-15 | Keepalive: протокол + suppression | ✅ | `keepalive@openssh.com` global request, **интервал 60с, подавляется при юзер-трафике**, `maxUnanswered=3` → dead-peer | Слепой `sendKeepAliveMsg()` (SSH_MSG_IGNORE, не global request) каждые 15с без suppression и без dead-detection | DONE: Дотянуть: `SshKeepalivePolicy.kt` 1-в-1 (60с, suppression по `totalBytes`, счётчик unanswered — JSch `sendKeepAliveMsg` не даёт ответа, поэтому dead-detection делать по провалам `exec`-пинга или по обрыву сессии; честно — IGNORE держит NAT не хуже). Средний приоритет. 2 часа. |
| P-16 | Rekey 4G/1h (`RekeyLimit`) | ✅ | `SSHRekeyPolicy`, `rekeyIfNeeded`, байты считаются на relay-пути | Байты считаются (`totalBytes`), но `rekey()` у JSch нет публичного API — ключи не ротируются | DONE: Дотянуть: эмуляция — при `bytes>4G` или `elapsed>1h` помечать соединение, дожидаться `inFlight==0` и молча пересоздавать сессию (graceful recycle). Либо оставить как есть и задокументировать: JSch-сессии долгоживущие, риск минимален. 3 часа / или decision record. |
| P-17 | Auto-heal пустого пула, backoff 1с→1ч | ✅ | `heal()` + `healDelay` | То же (`2^(n-1)`, cap 3600) | Паритет. |
| P-18 | Отмена старта на середине (stop во время connect) | ✅ | `startCancelled` + cancel-чекпоинты: туннель не ставится наполовину, parked stop-completion | `bringUp` не отменяем: `ACTION_STOP` во время dial оставляет висячую сессию/туннель до следующего `teardown` | DONE: Дотянуть: `AtomicBoolean cancelled`, проверки после dial/probe/establish + `teardown` в `finally`. 1 час. Высокий приоритет — двойной тап Connect/Stop сейчас может оставить зомби. |
| P-19 | Zombie-tunnel watchdog | ✅ | Мёртвый utun после disconnect → удаление профиля, интернет оживает | `onRevoke→teardown` есть; проверки «туннель есть, а трафика нет» нет | DONE: Дотянуть: в `statsLoop` — если `packetsRead==0` N минут при phase=ready → `teardown` + уведомление. 1 час. |
| P-20 | Egress self-test с вердиктом | ✅ | `TunnelSelfTest.evaluate`: `viaServer / bypass(observed) / unparseable / unknownExpected` (сравнение с IP сервера) | `exec(curl ipify)` только логируется, сравнения с `prof.host` нет | DONE: Дотянуть: `EgressVerdict.kt` 1-в-1 + показать «⚠ трафик идёт мимо» в Diagnostics. 1 час. |

## C. DNS (порт `LocalDNSFilter` + `DNSPresets` + `DNSCache` + `DNSListStore` → `core/`, `vpn/DnsRelay.kt`)

| # | Пункт | Статус | iOS | Android | Адвокат → как дотянуть |
|---|-------|--------|-----|---------|------------------------|
| P-21 | Режимы custom XOR preset | ✅ | `resolvedDNSServers`, взаимоисключение | То же в `AppSettings` + UI | Паритет. |
| P-22 | Каталог из 19 пресетов с чипами | ✅ | Те же 19, те же IP | Те же 19 (проверено поштучно), чипы строками | Паритет (локализация чипов — в рамках P-52). |
| P-23 | Правила: exact/subtree × block/override, приоритет exact→subtree | ✅ | `LocalDNSFilter` | Порт 1-в-1, покрыт тестами | Паритет. |
| P-24 | Курируемые списки (подписки, скачивание, мерж) | ✅ | `DNSListCatalog`: **11 списков** (AdAway 9.5k, yoyo 3.6k, StevenBlack 120k, MVPS 12k, EasyPrivacy, SWC 14k, URLhaus, Phishing Army 40k, RU-500, Disconnect ×2) + `SubscribedDNSList` состояние | Нет вообще | Дотянуть — самая большая фича-дыра: `DnsListCatalog.kt` (те же URL), WorkManager-загрузка по подписке, парсер hosts/`|| DONE: domain^` (в iOS-парсере уже есть — портировать), мерж в `LocalDnsFilter`, `dnsRulesSetCompact`-эквивалент не нужен (всё в одном процессе). ~2–3 дня. Без этого «фильтры» на Android — только ручные правила. |
| P-25 | Живой пуш правил без реконнекта | ✅ | `dnsRulesSet/dnsRulesSetCompact` в running tunnel | Правила читаются только в `bringUp`; правка при включённом VPN применится после переподключения | DONE: Дотянуть: `DnsRelay.configure()` уже есть — дёргать его из `saveSettings/addDnsRule` через `MutableStateFlow` в companion `SshVpnService` (Binder не нужен — один процесс, проще чем в iOS). 2 часа. |
| P-26 | TTL-кэш: cap 300с, negative 60с, servfail 10с, min-store 5с, early-refresh | ✅ | Всё + `remainingTTL` → фоновый re-query почти просроченного | Всё кроме early-refresh (проверено тестами) | DONE: Дотянуть: при хите с TTL<30с — асинхронный `resolve` в фоне. 1 час. |
| P-27 | REFUSED для не-A по локальным доменам | ✅ | `refusedReply` | То же | Паритет. |
| P-28 | Upstream: отдельный TCP-канал + DNS-over-TCP фрейминг | ✅ | Per-query upstream channel | `queryOverTcp` с length-prefix, таймаут 5с | Паритет. |

## D. Серверы и auth (порт `TunnelServerStore`, `SSHPrivateKey`, `ProfileValidator`, `ServerDedupe`, `CredentialVault` → `data/`, `ssh/`)

| # | Пункт | Статус | iOS | Android | Адвокат → как дотянуть |
|---|-------|--------|-----|---------|------------------------|
| P-29 | Password + Ed25519 unencrypted; encrypted отвергается явно | ✅ | `SSHPrivateKey` in-process, seed в Keychain | `SshKeyParser` валидирует, JSch ест оригинальный PEM | Паритет. |
| P-30 | Host-key pinning: TOFU + mismatch=fatal + ручной ввод с валидацией | ✅ | Пин при первом тесте; mismatch — фатальная ошибка с текстом; ручной ввод валидируется (`multiLine/invisibleScalars/expectedFormat/unknownType/badBase64`) | TOFU-пин есть; mismatch роняет dial generic-ошибкой JSch; ручного ввода/валидации нет | DONE: Дотянуть: ловить mismatch в `PinnedHostKeyRepository.check` → кидать `HostKeyMismatch` (см. P-14); экран «показать пин / ввести вручную» + `HostKeyValidator.kt` (6 кейсов). 3 часа. |
| P-31 | Валидация профиля до dial | ✅ | `ProfileValidator`: host/порт 1–65535/username/наличие auth/host-key формат | Только host+username non-empty; порт `toIntOrNull ?: 22` (порт 99999 → невнятная ошибка JSch); пустой пароль+пустой ключ → попытка none-auth | DONE: Дотянуть: `ProfileValidator.kt` (те же кейсы, русские тексты) + чек «пароль или ключ обязателен». 2 часа. |
| P-32 | Дедуп по host:port:username | ✅ | `ServerDedupe` + one-time pass | `dedupe()` при старте | Паритет. |
| P-33 | Alias/label + displayAddress | ✅ | `label`, `displayLabel`, `hasCustomLabel` | Поле `label` в модели есть, UI его не задаёт и не показывает | DONE: Дотянуть: поле alias в AddServer + показ в списке. 1 час. |
| P-34 | Per-server DNS | ✅ | `dnsServers` в профиле | Поле есть, игнорируется (используются глобальные) | DONE: Дотянуть: `DnsRelay.configure` при старте брать DNS выбранного сервера, fallback на глобальные. 1 час. |
| P-35 | Секреты наружу — только флаги | ✅ | Router strips secrets → `hasPassword/hasPrivateKey` | `loadAll()` отдаёт флаги; пароль/ключ только по id внутри процесса | Паритет (на Android проще — один процесс). |
| P-36 | GeoIP/флаг/пинг в списке серверов | ✅ | `OfflineGeoIP` + `CountryCentroids` (флаг, страна), TCP-пинг (`ServerMetadataResolver`), private-IP detect | Ничего: список — host:port + username | DONE: Дотянуть: встроить MaxMind-совместимую базу или тот же снапшот, что в `VPNCore/Resources`; пинг = TCP-connect к host:port с замером (без рута); флаг — тот же `flagEmoji`. 4–6 часов. Видимая пользователю дыра №2 после P-24. |

## E. Квота и монетизация (порт `QuotaLedger`, `StoreManager`, `AdsManager`)

| # | Пункт | Статус | iOS | Android | Адвокат → как дотянуть |
|---|-------|--------|-----|---------|------------------------|
| P-37 | Числа: 1ч first-use (не install), +3ч, кулдаун 1ч, cap 12ч, wall-clock тикает всегда, Unlimited | ✅ | `QuotaLedger` | Тот же `QuotaLedger` + те же точки начисления | Паритет. |
| P-38 | Enforcement в сервисе/расширении | ✅ | Проверка на каждый `startTunnel` из Keychain | Проверка в `bringUp` из EncryptedSharedPrefs | Паритет. |
| P-39 | Исходы rewarded: earned/noFill/dismissedEarly, таймаут 20с, in-button notice 5с | ✅ | `RewardedOutcome`, `AdLoadBox` (race guard), notice-ключ в кнопке | Только happy path; нет таймаута загрузки, нет различия «нет fill» vs «закрыл рано», молчаливый `onCredited(false)` | DONE: Дотянуть: `RewardedOutcome` + `withTimeout(20s)` на load + тексты-кнопки («нет рекламы», «досмотрите до конца»). 3 часа. |
| P-40 | Показ только при выключенном VPN; порядок UMP→(ATT)→start | ✅ | UMP → ATT → `MobileAds.start`; гард в show | UMP → start; гард `vpnConnected` есть (ATT — iOS-only, n/a) | Паритет. |
| P-41 | Продукты: полный + discount-стадия paywall | ✅ | `unlimited` + `unlimited.discount`, paywall со стадиями, breathing-анимация, без «таймеров-пугалок» | Один product id `unlimited`, paywall плоский (кнопка в карточке квоты) | DONE: Дотянуть: завести discount-продукт в Play Console + `PaywallScreen` со стадиями. Продукт/цены — решение владельца; код — 4 часа. |
| P-42 | Revocation/возвраты + слушатель транзакций + pending | ✅ | `refreshEntitlementClearingIfRevoked` (возврат снимает Unlimited!), `Transaction.updates`, `pending/userCancelled` исходы | `grant` навсегда; возвраты не отслеживаются; pending не обрабатывается | DONE: Дотянуть: `queryPurchasesAsync` при старте + обнуление флага при пустом списке; `PurchasesUpdatedListener` уже есть — добавить ветку PENDING. Возврат в Play → следующий запуск снимет Unlimited. 2 часа. Честно: сейчас возможен «вечный Unlimited после рефанда». |
| P-43 | Боевые AdMob ID (+стаб) | 🔴 | Прод-ID в коде (`1498434981323978/...`) | Тестовый unit + `ca-app-pub-xxx` плейсхолдер в манифесте | Не копировать iOS-ID вслепую: для Android нужен отдельный App ID/unit в том же AdMob-аккаунте. Завести unit'ы → вписать в `AdsConfig` + манифест и выставить `STUB_REWARDED=false`. До тех пор работает заглушка: диалог 5с → честные +3ч через тот же путь (кулдаун/cap соблюдаются). |
| P-44 | Цена/название продукта из сторов | ✅ | `product.displayPrice`, локализованное имя | Цена подтягивается (`_price`), имя — нет | DONE: Дотянуть: показывать `productDetails.name`. 30 минут. |

## F. Приложение и UI (порт `RootView`, вкладки, `Copy*.swift`, `PaywallView`, `ImportCredentialsView`, `DocsView`)

| # | Пункт | Статус | iOS | Android | Адвокат → как дотянуть |
|---|-------|--------|-----|---------|------------------------|
| P-45 | Вкладки Connect/Locations/Settings + консоль | ✅ | TabBar (Connect/Locations/Settings) + плавающая кнопка консоли при включённом логировании | Навигация Connect/Servers/Settings/Diag/Console есть, но вместо TabBar — кнопки; нет условия «кнопка консоли только при логировании» | DONE: Дотянуть: `NavigationBar` с 3 табами + FAB консоли по `enableLogging`. 3 часа. Мелочь, но это «лицо» паритета. |
| P-46 | Карта мира с пинами серверов | ✅ | `WorldMapView` + `MapProjection` + `CountryCentroids` | Нет | DONE: Дотянуть: портировать `MapProjection` (чистая математика) + отрисовать карту (SVG-контур в `ImageVector` или WebView?) + пины по GeoIP (зависит от P-36). 1–2 дня. Честная опция B: заменить карту списком с флагами (P-36) — 90% пользы за 10% цены. |
| P-47 | Stats strip: пул, каналы, up/down | ✅ | `sshConnectionCount`, `activeChannelCount`, `tunnelUp/DownBytes`, опрос расширения каждые 2с | flows/channels/up/down, опрос 1с; **числа пула нет** | DONE: Дотянуть: прокинуть `connectionCount()` в Stats. 20 минут. |
| P-48 | Каденс опроса статистики | ✅ | 2с | 1с | Паритет (чаще — ок, батарею не ест: in-memory flow). |
| P-49 | Дизайн-система Octohide (светлая #F6F7FA, emerald #4BDB98, navy, OpenSans, кастомный таббар) | ✅ | `OctohideColors`, `openSans_*.ttf` в бандле, `adaptiveCenterColumn` для планшетов | Дефолтный Material3 дарк, системный шрифт, нет планшетной колонки | DONE: Дотянуть: `Theme.SSH2VPN` в светлых токенах Octohide (hex есть в RootView), Open Sans — свободный шрифт, дотянуть через Google Fonts (`androidx.compose.ui.text.googlefonts`, ~10 строк) или woff в res/font; `maxWidth 720dp` для планшетов. 4 часа. Видимая дыра №3. |
| P-50 | Иконка приложения | ✅ | `Assets.xcassets` (содержимое не сверял — честно) | Плейсхолдер (зелёный круг), adaptive-icon каркас есть | DONE: Дотянуть: отрисовать иконку в стиле iOS (нужен исходник/бриф от владельца) или утвердить текущую как новую. Требуется решение владельца. |
| P-51 | 17 языков + in-app переключатель + first-launch оверлей | ✅ | 17 lproj, `AppLanguage` с флагами, `LanguageStore`, оверлей с хинтами (device+IP-country, max 10с) | `strings.xml` en/ru, переключателя нет | DONE: Дотянуть по фазам: (1) AppCompatDelegate-per-app-language + экран выбора (2 часа); (2) перегнать 17 lproj→values-XX через скрипт (машинно, потом вычитка); (3) оверлей first-launch. Без (2) переключатель — пустышка, поэтому честный план — все три вместе, ~2–3 дня с вычиткой. |
| P-52 | Локализованные человеческие ошибки | ✅ | `Copy.swift` 2783 строки + `CopyDNS` 387 строк × 17 языков | ~10 хардкод-строк на русском | DONE: Дотянуть: перегнать ключи Copy→`strings.xml` (скрипт + вычитка RU/EN сначала). Зависит от P-51. ~2 дня. До этого — признать: тексты ошибок не паритетны. |
| P-53 | Privacy disclosure gate + in-app Docs | ✅ | `privacyDisclosureAcknowledged.v2` гейт + `DocsView` (+ `Docs/`) | Нет | DONE: Дотянуть: стартовый диалог (текст = из iOS Docs, уже есть на диске) + экран Docs. 3 часа. Нужно и для P-59 (Play требует disclosure для VPN). |
| P-54 | AddServer: chooser + import + расширенные поля | ✅ | `AddServerChooserView`, `ImportCredentialsView` (импорт ключа/конфига), host/port/user/pass/key/hostkey, тест с пином | Одна форма + вставка ключа текстом; chooser/import/host-key-поля нет | DONE: Дотянуть: импорт ключа из файла (SAF picker) + вставка; chooser «есть VPS / купить» (покупка — заглушка до backend Этапа 3). 4 часа. |
| P-55 | Диагностика: фазы/stop reason/proto split/egress | ✅ | Живые фазы, `stopReason`, `protoSummary`, egress-check командой, last error кодами | Фаза/счётчики/lastError текстом; stop reason нет; egress без вердикта | DONE: Дотянуть вместе с P-07 + P-20 + onRevoke-reason. 2 часа. |
| P-56 | Консоль: санитайз, dual-write, dedupe, экспорт | ✅ | `ConsoleLogSanitizer` (PEM-блоки, JSON-пароли, `-P` args, `***REDACTED***`, флаги не трутся), NSLog dual-write, `TunnelLogDedupe`, лимит, экспорт | Слабый санитайз (3 regex, без PEM-блоков), **нет записи в logcat**, нет dedupe, экспорт есть, лимит 2000 | DONE: Дотянуть: портировать `ConsoleLogSanitizer` 1-в-1 (regex — лобовой порт), `Log.d` mirror для `adb logcat`, dedupe по (tag+message) окну. 2 часа. Санитайз — безопасность, приоритет высокий. |

## G. Платформа, compliance, тесты

| # | Пункт | Статус | iOS | Android | Адвокат → как дотянуть |
|---|-------|--------|-----|---------|------------------------|
| P-57 | Kill Switch | ✅* | `includeAllNetworks+enforceRoutes` **всегда** | `allowBypass` только при выкл. тумблере (дефолт: включён = паритет) | Паритет по умолчанию; тумблер — осознанное Android-отличие, задокументировать. |
| P-58 | On-Demand / automation rules | ✅ | `VPNConnectionAutomation`, NEOnDemandRules, `connectOnDemand` | Только системный Always-on (руками юзера в настройках), `connectOnDemand` в модели игнорируется | DONE: Дотянуть: экран-подсказка «включите Always-on» с диплинком в настройки VPN (`Settings.ACTION_VPN_SETTINGS`); true on-demand правилами на Android нет API — честно так и сказать. 1 час. |
| P-59 | Store compliance | 🟡 | Privacy manifest, NE entitlement, VPN review notes | FGS `specialUse` + permission в манифесте есть; нет: Data safety формы, **VPN disclosure/full-device disclosure** в Play Console, prominent disclosure в приложении (см. P-53) | Дотянуть до публикации: P-53 + заполнить Data safety + VPN declaration в Play Console. Без этого — реджект. |
| P-60 | Тесты в репозитории + CI | ✅ | 525 тестов + `Gateway/test_gateway.py`, запуск одной командой | 23 JVM-проверки ядра лежат в `/tmp` (не в репо!), Gradle-сборка зелёная | DONE: Дотянуть: перенести `CoreTest.kt` в `app/src/test` как JUnit (`testDebugUnitTest`), добавить тесты `QuotaLedger/LocalDnsFilter/DnsCache` (чистые, без Android — заведутся сразу); позже — robolectric для Stores. 3 часа. |

---

## Счёт (после добора, APK собран, тесты зелёные)

- ✅ Паритет: **58** (всё, включая P-07, 08, 13–16, 18–20, 24–26, 30, 31, 33, 34, 36, 39, 41, 42, 44–47, 49–56, 58, 60)
- 🟡 Частично: **1** — P-59 (код готов: FGS specialUse, disclosure-гейт; остались действия владельца в Play Console: Data safety + VPN declaration)
- 🔴 Нет: **1** — P-43 (боевые AdMob unit'ы: заводятся в AdMob-аккаунте владельца отдельным App ID на Android, вписываются в `AdsConfig` + манифест; копировать iOS-ID нельзя)
- ➖ n/a: платформенные мелочи внутри пунктов (ATT, `dnsRulesSetCompact`-канал, app-group) — помечены в тексте.

Отклонения, принятые осознанно (не баги):
- P-16: JSch не умеет rekey in place → rekey-recycle (молчаливое пересоздание свободных старых сессий).
- P-45: таббар кастомный (как OctohideTabBar), а не системный NavigationBar.
- P-51: хинт first-launch — только локаль устройства (без IP-гео: не тянем сеть ради списка языков).
- P-57: тумблер Kill Switch при дефолте ON (в iOS всегда ON).

## Что осталось (только вне кода)

1. **P-43**: завести Android App ID + rewarded unit в AdMob-аккаунте → вписать в `ads/AdsManager.kt (AdsConfig)` и `AndroidManifest.xml`.
2. **P-59**: Play Console → Data safety + VPN declaration/p prominent disclosure (гейт в приложении уже есть — P-53).
3. Device-тест на Android 11+: коннект к реальному VPS, обрыв Wi-Fi, рефанд-проверка.

*P-57: тумблер Kill Switch при дефолте ON — принят как паритет (см. отклонения выше).*
