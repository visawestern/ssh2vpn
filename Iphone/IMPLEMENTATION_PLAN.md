# ПЛАН ИМПЛЕМЕНТАЦИИ — Personal VPN iOS

> Синхронизирован 6 сент. 2026 с фактическим состоянием кода после перехода
> на relay-архитектуру (TCP поверх SSH direct-tcpip, без TUN/gateway на
> сервере). Формат: TDD-регламент сохранён; каждая глава — цель + статус +
> подпункты. Пункты, реализованные и покрытые тестами (525 тестов, 2 skipped,
> всё зелёное), отмечены `[x]` с указанием файла-носителя; устаревшие
> (относящиеся к TUN-режиму) помечены `SUPERSEDED`.

## Глава 0. Требования к каждой задаче (TDD-регламент)

Каждый новый подпункт подчиняется регламенту:

1. **Красный тест обязателен**: сначала тест, который падает; никакого кода до падающего теста.
2. **Крайние случаи**: пустые входы; границы 0/1/MAX/MAX+1; усечённые/битые данные; повторные вызовы; гонки; лимиты протокола; N+1-й reconnect; смена сети.
3. **Ответ и взаимодействие**: тест проверяет возврат и побочные эффекты (что отправлено в канал, что записано в Keychain, какой стейт у машины состояний).
4. Метки: `RED:` = сначала падающий тест; `EDGE:` = краевой случай; `INT:` = проверка взаимодействия.
5. Именование: `test<Func><Condition><Outcome>`.

## Глава 1. Валидация окружения VPS

**Статус: РЕАЛИЗОВАНО** (`VPSEnvironmentValidator.swift`, `VPSEnvironmentValidatorTests`; используется на legacy TUN-пути, модуль жив в VPNCore).

- [x] OS family/arch detection, python availability, outbound connectivity (`testValidatorRejectsUnknownOS`, `testValidatorRejectsUnsupportedArchitecture`, `testValidatorReportsUnreachableHost` и др.).
- [x] Результат валидации связан с построением команды gateway (`GatewayCommandBuilderTests`).
- [x] Кэш по fingerprint профиля, bounded retry (`GatewayCheckpointRetryPolicyTests`).

## Глава 2. Доставка gateway: бинарный стриминг + подпись

**Статус: РЕАЛИЗОВАНО как VPNCore-модули** (`GatewayArtifactVerifier`, `GatewayDeployCoordinator`, `GatewayDeploymentModeSelector`, `GatewayDeploymentOrchestrator` + тесты: fingerprint, paths, rollover, verifier, command builder, deploy coordinator, mode selector, orchestrator). **SUPERSEDED**: на активном relay-пути не используется — серверу не нужен артефакт. Оставлено для возможного возврата TUN-режима.

- [x] Ed25519-подпись + hash, ротация ключей с датой активации, tampered/truncated/empty отклоняются, порядок hash→signature→exec, install/temporary/remove-режимы, права 0700/0600 — всё покрыто тестами.

## Глава 3. Режимы установки и очистка артефактов

**Статус: РЕАЛИЗОВАНО** (`GatewayArtifactPaths`, `GatewayDeployCoordinator`: persistent/temporary/remove; тесты `GatewayArtifactPathsTests`, `GatewayDeployCoordinatorTests`). **SUPERSEDED** на relay-пути (артефактов нет — нечего чистить), модуль и тесты сохранены.

## Глава 4. Прерывания bootstrap и восстановление

**Статус: ЧАСТИЧНО РЕАЛИЗОВАНО, переформулировано под relay-старт.**

Актуальная цепочка старт-отмены (вместо стриминга файла): `startTunnel` → SSH connect → forwarding probe → (checkpoints: `post-ssh-connect`, `post-probe`) → `setTunnelNetworkSettings`. Реализовано и работает на устройстве:

- [x] Cancel checkpoint после SSH-коннекта и после probe — половины туннеля не остаётся (`abandonStartIfCancelled`, PacketTunnelProvider.swift).
- [x] Probe-fail (auth stuck / AllowTcpForwarding=no) → явная человеческая ошибка, `TunnelLastError`, никакого авто-ханга.
- [x] Early-death диагностика подключения с bounded авто-ретраем (`AppModel.diagnoseEarlyDeathAndMaybeRetry`).
- [x] Игнор stale-disconnect перед invoke (first-tap ghost).
- [ ] RED: `testPartialUploadCanResume`-класс задач — SUPERSEDED (нет стриминга артефакта).

## Глава 5. Надёжность транспорта и крайние случаи

**Статус: БОЛЬШИНСТВО РЕАЛИЗОВАНО.** Остались device/lab-пункты.

Реализовано (VPNCore + PacketTunnelProvider, покрыто тестами):

- [x] TCP-релей: sequence-aware receive, window scaling, backpressure, half-close (`TCPRelayTests`, `TCPRelayStateMachine`, `TCPSequence`).
- [x] UDP-reply builder с корректными checksums (`UDPReplyBuilderTests`) — путь DNS-релея.
- [x] SSH pool: рост по насыщению, least-loaded assignment, keepalive (`SSHConnectionPoolTests`, pool `keepalivePing`).
- [x] Frame queue bounded, ping/heartbeat budgets (`GatewayFrameQueueTests`, `PingBudgetTests`, `HeartbeatTrackerTests`).
- [x] DNS failure surfacing, TTL-кэш, local blocklist (`LocalDNSFilterTests`, `DNSRelayTests`).
- [x] v6/non-TCP-UDP пакеты классифицируются и dropped с счётчиками, без крэшей (proto split в `PacketTunnelPacketLoop`).
- [x] MSS-сегментация к телефону (throughput commit 5cc3ebe).
- [x] Zero-length read / EOF устойчивость (loop guards).

Осталось:

- [ ] `testSleepSuspendsWriteQueue` / `testWakeAfterLongSleepRebuildsSession` как device-тесты (suspend/resume реализованы, long-sleep rebuild не проверен на приборе).
- [ ] Memory pressure / max flow count под нагрузкой (профилирование Instruments).
- [ ] MTU-проверки на реальных сетях.

## Глава 6. Kill switch и анти-утечки

**Статус: РЕАЛИЗОВАНО в коде; device-доказательства остаётся собрать.**

- [x] `includeAllNetworks` + `enforceRoutes` в профиле; on-demand rules (`VPNConfigurationBuilderTests`, `applyOnDemandRules`).
- [x] Серверный IP исключать вручную не нужно — iOS keeps the physical route to the server by construction (см. комментарий в PacketTunnelProvider.swift:287); подсеть /24 через TunnelDevice не конфликтует с LAN.
- [x] Zombie-tunnel watchdog: мёртвый utun после disconnect → удаление профиля, интернет восстанавливается (`scheduleZombieTunnelCheck`).
- [x] Stall watchdog + minutely ping гарантируют различие «юзер неактивен» vs «flow умер».
- [x] Kill-switch-aware auto-reconnect (пропускается при исчерпании квоты).
- [ ] Leak-тест с tcpdump на устройстве (физический снифф) — не автоматизировано.
- [ ] `testLeakPulseDetector` — не реализован.

## Глава 7. Физическая верификация iOS (device)

**Статус: базовые проверки ПРОЙДЕНЫ** (см. `Docs/device-logs/2026-09-05-relay-traffic-flowing.log`, коммиты «On-device verified: traffic flows through the tunnel end-to-end», «On-device verified: throughput improved, self-healing works»; приложение установлено на устройстве, 525 тестов зелёные).

- [x] Entitlement в PacketTunnel, профиль грузится, cold boot start, multiple start/stop, kill extension → reconnect, Wi-Fi переходы — проверены вручную на приборе в ходе разработки.
- [x] Zombie/stall self-healing проверен на устройстве (коммит e4b459c/384d6f1).
- [ ] Формализованный протокол прогонов (чек-лист 140 пунктов) не ведётся — завести перед TestFlight.
- [ ] Instruments: leaks=0 за 15 мин активного VPN; battery profile — не сняты.

## Глава 8. Интеграционные тесты с реальным VPS

**Статус: ЧАСТИЧНО.** Live-relay тесты есть (`LiveRelayTests`, `RelayIntegrationTests` — против реального SSH/gateway harness в юнит-окружении). Остальное — lab-задачи:

- [x] `LiveRelayTests`, `RelayIntegrationTests`, `SSHRelayChannelTests`, `SSHRelayFactoryTests`, `SSHAuthenticationDelegateTests` — живой SSH-канал, пиннинг, auth.
- [x] Legacy gateway e2e: TCP/UDP echo через localhost (`Gateway/test_gateway.py`, 639 строк).
- [ ] Disposable Linux VPS harness на CI (nightly) — не настроено.
- [ ] tcpdump-доказательство выхода трафика с VPS, DNS leak negative — lab.
- [ ] Network Link Conditioner профили — не прогнаны формально.

## Глава 9. UI: My Servers и state-управление сервером

**Статус: РЕАЛИЗОВАНО (большая часть).**

- [x] Server list с пустым состоянием и onboarding CTA; выбор/удаление/редактирование (`TunnelServerStore`, `ServerListCoder`, `ServerDedupe`, `AppModel.loadServerList/saveServer/deleteServer/selectServer`).
- [x] Валидация ввода при добавлении (`ProfileValidatorTests`), дубликаты отвергаются (`ServerDedupeTests`).
- [x] State badge: Connecting → Preparing → Testing → Ready (фазы из расширения, phase polling).
- [x] Persistence через extension-owned store (`TunnelServerStoreTests`).
- [x] Переключение сервера без deadlock (коммит d69ece7), delete server flow.
- [x] GeoIP-метаданные: страна/флаг/город по IP (`ServerMetadataResolver`, refreshAllServerMetadata/AllServerPings с TTL).
- [x] Редактирование сервера (`VPNProfileEditor` + тесты), смена кредов → пере-авторизация.
- [x] Диагностика-переходы из карточки сервера (`DiagnosticsView`).
- [x] Язык: мгновенное переключение UI, 17 языков (`Localization.swift`, Copy/CopyDNS).
- [x] Long name truncation, VO-лейблы, expandable technical details.
- [ ] Expiration countdown / Extend CTA — не реализовано (нет purchased-серверов и поля expires_at).
- [ ] «Купить VPS» — нет flow (зависит от Этапа 3, Гл. 10).

## Глава 10. VPS Provisioning adapter (Этап 3)

**Статус: НЕ НАЧАТ.** Пункты 181–200 остаются как есть (см. ниже), без изменений.

- [ ] 181. RED: `testProviderRegistryDiscovers` — список провайдеров из конфига.
- [ ] 182. `testProviderAPIVersionAssert` — v1/v2 манифест.
- [ ] 183. `testProviderCreateOrder` — создание заказа у провайдера.
- [ ] 184. `testProviderPollOrderStates` — polling статусов (pending→active).
- [ ] 185. EDGE: `testProviderTimeoutOnPoll` — таймаут poll → понятная ошибка.
- [ ] 186. `testProviderFetchCredentials` — способы доставки: password / private key.
- [ ] 187. `testCredentialsEncryptionAtRest` — секреты в Keychain, не в plaintext JSON профиля.
- [ ] 188. `testProviderCreateFailTransientRetry` — transient retry с backoff.
- [ ] 189. `testProviderOrderCancellation` — cancel против half-created VPS.
- [ ] 190. `testProviderPlanMatrix` — планы: CPU/RAM/срок (из ТЗ §8.2).
- [ ] 191. `testProviderCountriesFilter` — фильтр по странам.
- [ ] 192. `testProviderHistorySnapshot` — журнал заказов.
- [ ] 193. `testProviderWebhookEvent` — партнёрский webhook.
- [ ] 194. `testProviderRequestSigning` — подпись запросов.
- [ ] 195. `testProviderSecretsNeverLogged` — redaction секретов в логах.
- [ ] 196. `testProvisioningStateMachine` — pending/creating/ready/failed.
- [ ] 197. RED: `testProvisioningThenAutoAddServer` — готовый сервер автоматически добавляется в My Servers.
- [ ] 198. EDGE: `testDuplicateOrderIdGuard` — идемпотентность заказов.
- [ ] 199. `testProviderDeadlineExpiry` — умирает заказ → release.
- [ ] 200. INT: `testProvisioningCancelsOnAppDisconnect` — пользователь вышел из флоу → cancel.

## Глава 11. Backend (Этап 4)

**Статус: НЕ НАЧАТ.** Пункты 201–220 без изменений.

- [ ] 201. RED: `testLicenseVerifySignature` — app-лицензия подписана сервером.
- [ ] 202. `testTrialPeriodStartedOnce` — одно устройство / один trial. *(Частично покрыто продуктовым решением: вместо backend-trial реализована локальная квота 3 ч + rewarded-ad — см. AdQuota.)*
- [ ] 203. `testTrialExpiryGrace` — grace-период.
- [ ] 204. `testServerStateEndpoint` — единый источник статуса сервера.
- [ ] 205. `testOrderCrud` — create/read/cancel/replace.
- [ ] 206. `testWebhookSignatureVerification` — HMAC.
- [ ] 207. `testWebhookReplayProtection` — nonce/timestamp.
- [ ] 208. `testWebhookAtLeastOnceIdempotent` — повторная доставка не меняет состояние.
- [ ] 209. `testProviderAbstractionResolver` — map провайдер→API-драйвер.
- [ ] 210. `testEncryptedSecretsAtRest` — шифрование секретов в БД.
- [ ] 211. `testRotateEncryptionKey` — ротация ключей без потерь.
- [ ] 212. `testUserDeviceCap` — привязка license к устройству.
- [ ] 213. `testLicenseOfflineGrace` — offline-работа N дней.
- [ ] 214. `testServerReplacementFlow` — replace старого сервера.
- [ ] 215. `testServerExtendFlow` — продление.
- [ ] 216. `testExpiredServerCleanup` — истечение → release + notify.
- [ ] 217. `testAdminPanelReadOnly` — role-контроль панели.
- [ ] 218. INT: `testBackendErrorsSurfaceInApp`.
- [ ] 219. RED: `testProvisioningThenAutoAdd`.
- [ ] 220. `testWebhookDeadLetter`.

## Глава 12. In-App Purchase (Этап 6)

**Статус: НЕ НАЧАТ.** Пункты 221–240 без изменений.

- [ ] 221. RED: `testStoreKitConfigEnums` — продукты: сервер на месяц/год + lifetime app.
- [ ] 222. `testProductFetch` — storefront fetch, пустой/offline — clean error.
- [ ] 223. `testPurchaseFlowReceipt` — успех → originalTransactionId.
- [ ] 224. `testRestorePurchases`.
- [ ] 225. `testPurchaseServerThenConnectChain` (INT).
- [ ] 226. `testServerRenewalUsesSameVPS`.
- [ ] 227. `testSubscriptionCancellationGrace`.
- [ ] 228. `testPaymentFailureSurface`.
- [ ] 229. `testNoBackgroundLeakOnPayment`.
- [ ] 230. `testLocalReceiptValidation` — StoreKit2.
- [ ] 231. `testServerSideReceiptValidation`.
- [ ] 232. EDGE: `testDoubleTapPurchase`.
- [ ] 233. `testPurchaseDuringProvisioning` — гонка order↔purchase.
- [ ] 234. `testSandboxReceiptNeverInProd`.
- [ ] 235. `testNoPromoInSandboxAccident`.
- [ ] 236. `testLocalePriceString` — 17 локалей, форматирование валют.
- [ ] 237. `testExpirationDateAccuracy`.
- [ ] 238. `testOfflinePurchaseHang`.
- [ ] 239. INT: `testPurchaseBlockedWhileNoBackend`.
- [ ] 240. `testRefundWebhookGrantsRefund`.

## Глава 13. App Store / Privacy compliance и TestFlight (Этап 8)

**Статус: НЕ НАЧАТ; вводные обновлены** (17 языков вместо 6; зависимость только SwiftNIO-family, все Apache-2.0).

- [ ] 241. `testPrivacyPolicyReviewed` — трафик только через пользовательский VPS.
- [ ] 242. `testPresenceInManifest` — App Privacy: типы данных, purpose strings.
- [ ] 243. `testVPNPurposeString`.
- [ ] 244. `testNoServerLoggingImpact` — сервер не логирует контент (в relay-режиме сервер вообще без нашего ПО — утверждение упростилось).
- [ ] 245. `testKeychainEntitlementExplicit`.
- [ ] 246. `testDataUseDeclarationsForNSPrivacy` — `NSPrivacyAccessedAPITypes`.
- [ ] 247. `testTestFlightDistributionMetrics`.
- [ ] 248. `testTestFlightBetaInviteForCarriers`.
- [ ] 249. `testAssertNoThirdPartySDK` — зависимости: swift-nio, swift-nio-ssh, swift-crypto (Apache-2.0).
- [ ] 250. `testLicenseComplianceFiles` — LICENSE notices в bundle.
- [ ] 251. `testOptOutOfDeviceDiagnostics`.
- [ ] 252. `testAndroidStoreSplit` — (Этап 7).
- [ ] 253. `testAppReviewReadinessDoc`.
- [ ] 254. `testNoProhibitedContent` — формулировки «навсегда бесплатный» исключены. **ОСТОРОЖНО**: текущая модель (3 ч бесплатно + реклама за +3 ч) — проверить формулировки в сторе; само приложение называется «vpnfreeforever» — риск-пункт для ревью.
- [ ] 255. `testBuyVPSFlowNotForbiddenByApple` — покупка сервера — внешний компонент: ToS.
- [ ] 256. `testTwoAccountLimitsGraceful`.
- [ ] 257. `testGDPRDeleteRequest`.
- [ ] 258. `testKeyRetentionPolicy`.
- [ ] 259. `testReviewRejectionDrill`.
- [ ] 260. `testMetadataLocalized` — на 17 языках.

## Глава 14. CI

**Статус: базовый CI ЕСТЬ** (`.github/workflows/tests.yml`: macOS swift test + ubuntu python gateway tests на push/PR).

- [x] `testCIBuildGreen` — пакет собирается и тесты гоняются на CI (261).
- [x] `testGatewayRuffLintGate`-эквивалент: gateway-тесты в CI (python job).
- [ ] 262. `testCoverageGate70` — ≥70% unit-global.
- [ ] 263. `testCoverageGate60NewCode`.
- [ ] 264. `testSwiftFuzzIntegration` — fuzz-джоба nightly.
- [ ] 265. `testFuzz30MinutesNoCrash`.
- [ ] 266. `testFuzzFindingsTriaged`.
- [ ] 267. `testDeterministicCorpusKept` — корпус уже частично есть (`TransportFuzzTests` в репо).
- [ ] 268. `testRegressionCorpusAutomated`.
- [ ] 269. `testGatewayPythonMypyStrict` — SUPERSEDED частично: gateway.py не на активном пути; проверить mypy всё же стоит.
- [ ] 271. `testXcodeBuildBotGreen` — сборка Xcode-проекта в CI не настроена (нужен macOS runner с подписью из проекта).
- [ ] 273. `testCIArtefactSigned`.
- [ ] 274. `testNightlyIntegrationTag` — nightly e2e/VPS.
- [ ] 275–280. Coverage regression, mutation baseline, static analyzer, fast feedback, crash reporter, release pipeline — не настроены.

## Глава 15. Multi-hop (Этап 9)

**Статус: НЕ НАЧАТ.** Пункты 281–300 без изменений (полный список сохранён в git-истории этого файла; выжимка ниже).

- [ ] 281. RED: `testChainConfigVPS1VPS2`.
- [ ] 282–285. Chain handshake pipelined, SSH jump через VPS1, idempotent teardown, second-hop failure kills chain.
- [ ] 286–290. First-hop survives second reconnect, latency budget, no IP overlap, v4/v6 mixed, kill switch per hop.
- [ ] 291–300. Diagnostics per hop, отдельные креды в Keychain, cleanup, no public listener, bounded backoff per hop, hop swap mid-session, zero-hop rejected, UI gated, телеметрия без IP хопов, chain timeout bound.

## Глава 16. TLS transport (Этап 10)

**Статус: НЕ НАЧАТ.** Пункты 301–320 без изменений (выжимка; полный список в истории файла).

- [ ] 301–310. Custom protocol over TLS 1.3 (ALPN), cert validation/pinning против собственного CA, mutual auth, replay protection, derived keys, rate limit, unauthorized-relay rejection, no traffic storage, data-plane параллелен SSH (общий интерфейс транспорта), fallback к SSH.
- [ ] 311–320. Cert pin fallback, SSH-vs-TLS benchmark, captive-proxy/firewall режимы, expert-настройка gate, cellular battery metric, no-obfuscation promise, crypto budget (TLS 1.3, AEAD), `SessionHandshake` reuse, A/B gate через конфиг.

---

# Часть B. Причинно-следственные цепочки функций + тесты

> Обновлено под relay-архитектуру. Цепочки C1/C2/C3 относятся к legacy
> flow-протоколу (реализованы и протестированы, но не на активном пути);
> C4–C5 — активная relay-цепочка; C10 — SUPERSEDED; C12 — зависит от Этапа 6.

## C1. Подключение: Connect → system VPN (relay)

**Цепочка (актуальная):** `AppModel.connect` (quota gate) → `VPNController.start` → `NETunnelProviderManager` save/reload → extension `startTunnel` → `SSHTransportFactory.connect` (pinned host key) → forwarding probe (direct-tcpip → 8.8.8.8:53) → `SSHConnectionPool` → `RelayTransport.start` → `setTunnelNetworkSettings` (v4-only) → `packetFlow` read loop → TCP flows → direct-tcpip channels.

- [x] Тест: `SSHAuthenticationDelegateTests`, `SSHRelayChannelTests`, `SSHRelayFactoryTests`, `LiveRelayTests` — auth/pin/channel путь; probe-логика проверена на устройстве.
- [ ] EDGE: probe timeout против мёртвого sshd в CI-харнесе; повторный connect при активном (идемпотентность) — device-прогон.
- [x] INT/Ответ: после каждого шага фаза пишется в `tunnelPhase`, апп тянет её через `status` message (`AppModel.startPhasePolling`), счётчики `PacketTunnelPacketLoop` видны в Diagnostics.

## C2. Кадровый протокол (legacy flow mode; сохранён для истории/модульных тестов)

- [x] Round-trip через 1-байтовую фрагментацию, malformed/oversized фреймы, reserved bits, unknown version/type — `FrameDecoderTests`, `TransportFrameTests`, `TransportFuzzTests`. SUPERSEDED на активном пути (direct-tcpip несёт payload сам).

## C3. Аутентификация SSH + пиннинг host key

**Цепочка:** `SSHTransportFactory.connect` (hostKeyPinned) → смена ключа → `SSHAuthenticationDelegate` reject → человеческая ошибка в UI + `TunnelLastError`.

- [x] Тесты: `SSHAuthenticationDelegateTests` (wrong password, key mismatch, pinning reject); UI-маппинг `sshAuthFailed`/`sshHostKeyMismatch` локализован.
- [x] EDGE: port closed / host not resolvable / timeout — покрыты `SSHEndpointResolverTests` и обработкой ошибок.

## C4. Relay: utun packet → direct-tcpip → reply

**Цепочка:** `PacketTunnelPacketLoop.readPackets` → proto-split классификатор → TCP → `TCPRelayStateMachine` (seq/window) → `SSHConnectionPool.open` (least-loaded) → NIOSSH direct-tcpip → данные → reply builder (checksums, MSS) → `packetFlow.writePackets`.

- [x] Тесты: `TCPRelayTests`, `RelayPacketTests`, `RelayIntegrationTests`, `UDPReplyBuilderTests`, `LiveRelayTests`.
- [x] EDGE: truncated IPv4, не-TCP/UDP dropped с счётчиками, DNS порт-53 отдельно.
- [ ] INT: pool grow/scale-out под реальной нагрузкой — device-лог есть, CI-харнес нет.

## C5. DNS relay: правило → фильтр → upstream → кэш → reply

**Цепочка:** utun UDP:53 → `LocalDNSFilter` (block → A 0.0.0.0 / override → custom IP; точное/поддерево) → miss → per-query upstream TCP channel (custom или preset IP) → ответ кэшируется (TTL-capped, hard cap 300 s) → `UDPReplyBuilder` → utun.

- [x] Тесты: `LocalDNSFilterTests`, `DNSRelayTests`, `DNSPresetsTests` (19 пресетов, chips), `AppSettingsStateTests` (mutually exclusive custom/preset, IPv4-literal validation).
- [x] FIX в проде: расширение перезаписывало свежевыбранный DNS устаревшей копией (коммит ff82304) — регресс-кейс в тестах настроек.

## C6. Реконнект и self-healing

**Цепочка:** канал умер/сеть изменилась → `NWPathMonitor`/heartbeat → bounded backoff → новый SSH + probe → pool rebuild → phase → UI «reconnecting».

- [x] Тесты: `StateMachineTests`, `GatewayReconnectControllerTests`, `RetryBudgetTests`, `HeartbeatTrackerTests`.
- [x] Zombie/stall watchdog на устройстве (коммиты e4b459c, 384d6f1).
- [ ] EDGE: airplane mode / carrier switch формальные device-прогоны.

## C7. Quota: connected time → consume → block → ad refill

**Цепочка:** тикер connected-времени (`VPNConnectionAutomation.activeSeconds`) → `AdQuota.consume` → `remainingQuotaSeconds == 0` → блок connect + disconnect + локализованная ошибка `failureFreeTimeExhausted`; `watchAd` (+3 h, cooldown 1 h, bank ≤ 3) → `AdQuotaStore.save`.

- [x] Тесты: `AdQuotaTests` (free grant drain order, cooldown, bank cap, boundary at exactly-0).
- [ ] INT: real rewarded-ad SDK — нет (заглушка 2 s).

## C8. Kill switch / маршруты

- [x] `includeAllNetworks`+`enforceRoutes`, on-demand rules, quarantine reconnect: код и тесты (`VPNConfigurationBuilderTests`, `VPNConnectionAutomationTests`).
- [ ] Физический leak-снифф — lab.

## C9. Extension↔App messaging

**Цепочка:** app `VPNExtensionAPI.call` → `sendProviderMessage` → `TunnelAppMessageRouter.dispatch` (status/lastError/serverList/serverGet/serverSet/serverDelete/serverSelect/logs) → JSON-ответ → UI/`ConsoleLogStore.ingestExternal`.

- [x] Тесты: `TunnelAppMessageRouterTests`, `ServerListCoderTests`, `TunnelServerStoreTests`, `TunnelLogDedupeTests`, `ConsoleLogIngest/Sanitizer/ExportTests`.
- [x] EDGE: timeout → пустой результат без hang (`OSAllocatedUnfairLock` single-resume).

## C10. Бинарь и подпись → запуск → cleanup (SUPERSEDED)

Реализовано и покрыто (`GatewayArtifactVerifierTests`, `GatewayDeployCoordinatorTests`, `GatewayDeploymentOrchestratorTests`, `GatewayCheckpointRetryPolicyTests`), но не на активном relay-пути. Актуально только при возврате TUN-режима.

## C11. Sleep/wake и suspension

- [x] `PacketTunnelPacketLoop.suspend/resume` реализованы; resume при умершем транспорте перестраивает соединение.
- [ ] Device-прогон долгого сна (>5 мин) — checklist Гл. 7.

## C12. Покупка → Provision → Auto-add → Connect (Этап 3+6)

**Статус: НЕ НАЧАТ** — цепочка ждёт провайдер-адаптера и StoreKit. Пункты из Глав 10/12.

## C13. Reconnect ↔ Kill switch ↔ Network transitions

- [x] Код: path monitor → teardown → kill switch держит блок → bounded reconnect → probe → READY.
- [ ] Формальный device-прогон с leak-сниффером — lab, Гл. 8.

---

# Часть C. Что делать дальше (приоритеты на текущем срезе)

1. **Relay e2e harness на disposable VPS** (Гл. 8): docker/VPS + sshd, nightly CI, tcpdump-утверждение выхода трафика, DNS-leak negative.
2. **Device-протокол** (Гл. 7): формализованные прогоны sleep/wake, airplane, carrier switch, Instruments leaks/battery.
3. **Coverage/fuzz гейты CI** (Гл. 14): coverage ≥70%, nightly fuzz job, corpus regression.
4. **Продуктовые этапы**: Гл. 10 (provisioning adapter) → Гл. 11 (backend) → Гл. 12 (IAP) — по мере готовности бизнеса; expiration-поля в store и UI уже спроектированы под это.
5. К марафону App Store (Гл. 13): privacy manifest, purpose strings, обзор формулировок free/rewarded в текущей квота-модели.
