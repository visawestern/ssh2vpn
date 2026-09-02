# ПЛАН ИМПЛЕМЕНТАЦИИ — Personal VPN iOS

Полный развёрнутый чеклист работ. Каждый важный пункт — глава, в каждой главе не менее 20 подпунктов. В конце — причинно-следственные цепочки между функциями с тестами (TDD, красный тест, крайние случаи, проверка ответа и взаимодействия).

## Глава 0. Требования к каждой задаче (TDD-регламент)

Каждый подпункт подчиняется регламенту. Если в подпункте не указано иное, применяется:

1. **Красный тест обязателен**: сначала тест, который падает (красный/зелёный/рефакторинг; никакого кода до падающего теста).
2. **Крайние случаи**: пустые входы; границы 0/1/MAX/MAX+1; усечённые/битые данные; повторные вызовы; гонки и параллелизм; повторный вход в состояние; лимиты протокола; N+1-й reconnect; смена сети.
3. **Ответ и взаимодействие**: тест проверяет не только возврат, но и побочные эффекты цепочки (что получено кодеком, что отправлено в канал, что записано в Keychain/AppGroup, какой стейт у `ConnectionStateMachine`).
4. Метка формата: `RED: <условие>` = сначала падающий тест. `EDGE:` = краевой случай. `INT:` = проверка взаимодействия двух функций.
5. Именование тестов: `test<Func><Condition><Outcome>`.

## Глава 1. Валидация окружения VPS перед bootstrap

**Цель**: ресурсы `SSHEndpointResolver/SSHTransport` + новая `VPSEnvironmentValidator`; закрыть пункт CHECKLIST «Validate OS, architecture, permissions, and outbound connectivity».

- [ ] 1. RED: `testValidatorRunsBeforeBootstrap` — проверка запускается прежде выполнения gateway, сразу после первого SSH-канала.
- [ ] 2. EDGE: `testNoExtraSSHSessionCreated` — валидация не создаёт лишних SSH-сессий (использует существующий канал bootstrap).
- [ ] 3. `testOSFamilyDetected` — Linux/glibc, musl распознаются, значения ожидаемые.
- [ ] 4. `testOSFamilyNotDetected` — unknown → ошибка `unsupportedOS`.
- [ ] 5. RED: `testIsArchSupported` — aarch64 и x86_64 принимаются, остальные — нет.
- [ ] 6. EDGE: `testX86_64UnsupportedOnIOSLikeTargets` — защита от выбора intel-only gateway на неподходящей платформе.
- [ ] 7. `testPython3MinimumVersion` — отказ ниже 3.8, принятие 3.9+.
- [ ] 8. EDGE: `testPythonUnavailable` — `python3` нет в PATH → `gatewayUnavailable`, а не падение.
- [ ] 9. `testPermissionsCheckExecutableHome` — отсутствие прав `0700` на временную папку → понятная ошибка.
- [ ] 10. EDGE: `testHomeReadOnlyFallsBackQuietly` — fallback в `$TMPDIR`, без выноса секретов.
- [ ] 11. `testOutboundConnectivityCheckToVPS` — reachable host; порт SSH открыт через bounded `connect(timeout:)`.
- [ ] 12. EDGE: `testConnectivityCheckTimeout` — таймаут → явная ошибка, `NetworkExtension` получает `NEVPNError`.
- [ ] 13. EDGE: `testConnectivityCheckPacketLossTolerant` — дропы потери на канале не отменяют проверку.
- [ ] 14. `testCaptivePortalDetected` — HTTP 302/страница логона → warning `captivePortal` (не блокировка).
- [ ] 15. INT: `testValidatorResultFeedsGatewayCommandBuilder` — результат валидации передаётся в `GatewayCommandBuilder.pythonInline`.
- [ ] 16. INT: `testValidationSkipFlagPreservesBackcompat` — флаг «skip validate» для повторного подключения.
- [ ] 17. `testValidationRunsOnlyOncePerProfile` — кэш результата по fingerprint профиля.
- [ ] 18. EDGE: `testConcurrentValidations` — два параллельных connect не гонятся.
- [ ] 19. INT: `testValidatorReportsToDiagnosticsView` — результат приходит в `DiagnosticsView`.
- [ ] 20. `testValidationFailureSurfacesBeforeInvoke` — сбой валидации блокирует запуск gateway, а не падает в фоне.

## Глава 2. Доставка gateway: бинарный стриминг + подпись

**Цель**: закрыть «Prefer streaming a signed Go binary…», «Verify artifact signature/hash before execution».

- [ ] 21. RED: `testBinaryServedOnlyAfterHashVerified` — без валидного хэша gateway не запускается.
- [ ] 22. `testEd25519SignatureOfBinaryAccepted` — сигнатура проверена открытым ключом приложения.
- [ ] 23. EDGE: `testTamperedBinaryRejected` — 1 бит перевёрнут → `signatureMismatch`.
- [ ] 24. EDGE: `testTruncatedBinaryRejected` — обрезка → `hashMismatch`.
- [ ] 25. EDGE: `testEmptyBinaryRejected` — ноль байтов → ошибка до запуска.
- [ ] 26. RED: `testStreamingChunksWithProgress` — поток пишется чанками (64 КБ), прогресс приходит в UI.
- [ ] 27. EDGE: `testInterruptedStreamCorruptsNothing` — разрыв → временный файл удаляется, артефакт не тронут.
- [ ] 28. `testBinaryModeSelectedOverPython` — бинарь доступен и архитектура совпадает → приоритет бинарному режиму.
- [ ] 29. `testPythonFallbackWhenBinaryUnavailable` — ровно обратный случай.
- [ ] 30. `testPublicKeyRollover` — поддержка 2 ключей (старый+новый) с датой ротации.
- [ ] 31. EDGE: `testRolloverGracePeriod` — подпись новым ключом до даты активации → rejected.
- [ ] 32. `testVerifyAgainstSha512Manifest` — мульти-файловый манифест и его валидация.
- [ ] 33. `testBinarySizeUpperBound` — размер > лимита (2 МБ) → отказ до стриминга.
- [ ] 34. EDGE: `testZeroSizeBinary` → явная ошибка.
- [ ] 35. INT: `testSignatureCheckBeforeExecution` — порядок: hash → сигнатура → exec, через mock executor.
- [ ] 36. `testDownloadFailsSuggestsOfflineBundle` — недоступность CDN → предложение оффлайн-бандла из bundle.
- [ ] 37. RED: `testNoExecutionWithoutReady` — команда gateway построена только после readiness.
- [ ] 38. INT: `testAssertExecutionNeverDuplicates` — повторный вызов не стартует второй процесс.
- [ ] 39. EDGE: `testConcurrentStreamsSameKey` — параллельные bootstrap не пересекают временные файлы (UUID-префикс).
- [ ] 40. EDGE: `testPartialNextReadAfterStreamError` — read-back после поломки не возвращает мусор.

## Глава 3. Режимы установки и очистка артефактов

**Цель**: закрыть «Add explicit install/temporary-session/remove modes», «Clean temporary artifacts».

- [ ] 41. RED: `testInstallModePersistsGateway` — install/cache кладёт бинарь в постоянную папку, права `0700`.
- [ ] 42. `testTemporaryModeNeverPersists` — каждый раз удаляет после disconnect.
- [ ] 43. `testRemoveModeCleansHostAndLocalState` — локаль + постоянная папка + AppGroup.
- [ ] 44. EDGE: `testRemoveModeIdempotent` — вызов дважды не падает.
- [ ] 45. `testTemporaryArtifactsDeletedOnSuccess` — normal disconnect → cleanup.
- [ ] 46. RED: `testTemporaryArtifactsDeletedOnFailedSetup` — провал bootstrap → cleanup тоже.
- [ ] 47. EDGE: `testCleanupSurvivesKernelReject` — ошибка удаления не превращается в исключение, файл помечается.
- [ ] 48. `testRemoveModeRevokesKeyFromAuthorizedKeys` — удаление ключа с VPS (документированные риски).
- [ ] 49. EDGE: `testRevokeAgainstMissingKeyStillClean` — ключа нет → без ошибки, итог «no-op» корректен.
- [ ] 50. `testInstallFingerprintUniquePerHost` — `sha256(host+user)` в именах артефактов.
- [ ] 51. INT: `testRemoveUsesSafeLockOrder` — блокировки `SSHTransport` и `VPNController` без deadlock.
- [ ] 52. EDGE: `testDisconnectDuringInstall` — гонка clean↔install → либо rollback, либо success, но не partial.
- [ ] 53. EDGE: `testReinstallOverOldVersion` — старая версия заменена, сигнатура новой проверена.
- [ ] 54. `testArtifactDirPrivate0700` — stat-тест прав директории.
- [ ] 55. RED: `testRemoveDuringConnectedReturnsError` — нельзя удалять, пока соединение активно.
- [ ] 56. `testTemporaryFilesNeverWorldWritable` — права временных файлов не слабее `0600`.
- [ ] 57. INT: `testInstallThenTemporarySequenceClean` — install → temp → remove — каждая стадия изолирована.
- [ ] 58. `testCleanupReportsFailuresForDiagnostics` — падение cleanup видно в `DiagnosticsView`.
- [ ] 59. EDGE: `testHostNameWithUnicodeUnsafePaths` — нормализация путей.
- [ ] 60. INT: `testCleanupCalledInGatewayErrorPath` — `Gateway.exitsUnexpected` → cleanup запущен.

## Глава 4. Прерывания bootstrap и восстановление

**Цель**: закрыть «Partial upload/interrupted bootstrap».

- [ ] 61. RED: `testPartialUploadCanResume` — чанковый стрим поддерживает resume offset.
- [ ] 62. EDGE: `testPartialUploadTruncatesCleanly` — прерывание → удалено, нет полу-файла.
- [ ] 63. `testUploadTimeoutBreaksStream` — таймаут потока → явная ошибка + cleanup.
- [ ] 64. `testClientDisconnectDuringUploadShowsExplicitError` — пользователь отключился → cancel, не hang.
- [ ] 65. `testGatewayAckRequiredBeforeTraffic` — готовность гейта после полного файла, поток ждёт.
- [ ] 66. RED: `testHandshakeCheckpoint` — контрольная точка восстанавливает поток с места разрыва.
- [ ] 67. `testCheckpointRetriesBounded` — max 3 retry, потом fail + bounded backoff.
- [ ] 68. EDGE: `testZeroByteCheckpoint` — пустая контрольная точка → не восстанавливать.
- [ ] 69. INT: `testBootstrapStateSurvivesProcessDeath` — состояние bootstrap в `ConnectionStateMachine` сохраняется.
- [ ] 70. `testReconnectUsesResumeNotFullRestart` — временный сбой сети → resume, а не полный рестарт.
- [ ] 71. EDGE: `testReconnectAfterFullFailureDoesFullReinstall` — фатальный сбой → полный bootstrap (файл битый).
- [ ] 72. `testValidationPhaseNotRepeatedOnResume` — resume пропускает валидацию (кэш).
- [ ] 73. EDGE: `testResumeOffsetBeyondFileSizeRejects` — offset > размера файла → отказ.
- [ ] 74. `testProgressCallbackMonotonic` — прогресс монотонен (RED при скачках).
- [ ] 75. INT: `testPartialScriptKeptForDebug` — битые чанки видны в `DiagnosticsView`.
- [ ] 76. RED: `testBootstrapAttemptsCoalesce` — 3 сбоя bootstrap = 1 понятная ошибка, не 3 popup'а.
- [ ] 77. `testBootstrapReadinessOnlyAfterConnectivityProbe` — инвариант ARCHITECTURE.md:7.
- [ ] 78. EDGE: `testExtensionTerminatedMidBootstrapRecovers` — перезапуск продолжает с checkpoint.
- [ ] 79. INT: `testCleanupChainAfterFailedResume` — cleanup вызван в каждой ветке ошибок (таблица).
- [ ] 80. EDGE: `testMaxBootstrapRetryEnforced` — лимит → `failed(.gatewayUnavailable)`.

## Глава 5. Надёжность транспорта и крайние случаи

**Цель**: закрыть sleep/wake, DNS failure, MTU, packet loss, captive, IPv4-only, memory pressure.

- [ ] 81. RED: `testSleepSuspendsWriteQueue` — очередь при `sleep` становится suspended.
- [ ] 82. EDGE: `testWakeResumesQueuedFramesInOrder` — порядок не нарушен после `resume` (INT с `PacketTunnelPacketLoop.suspend/resume`).
- [ ] 83. EDGE: `testWakeAfterLongSleepRebuildsSession` — сон > лимита (5 мин) → полный разрыв + reconnect.
- [ ] 84. `testAppSuspendCancelsAndRestoresState` — `AppModel` не теряет стейт после kill при активном VPN.
- [ ] 85. RED: `testDNSFailureSurfacesGateError` — DNS не резолвится → `ssendpointResolverError`, не тихий фейл.
- [ ] 86. `testMTUSizeAdvertisedToTunnel` — IPv4 1400 / IPv6 1380, фрагментация без потерь.
- [ ] 87. EDGE: `testOversizedPacketRejectedBeforeSend` — пакет > MTU+overhead → отброс в `RawPacketBridge`.
- [ ] 88. `testPacketLossDoesNotCorruptFrame` — стресс 5% loss в харасе, фрейм цел.
- [ ] 89. EDGE: `testReorderDoesNotDropLeak` — reorder не ломает TCP/UDP очередь.
- [ ] 90. RED: `testCaptivePortalSurface` — отлов и предупреждение, а не popup.
- [ ] 91. `testIPV4OnlyVPSWorks` — без IPv6 не строить маршрутов IPv6.
- [ ] 92. RED: `testIPv6PacketsDroppedGracefullyOnV4Only` — исключение отсутствует; счётчик dropped растёт.
- [ ] 93. `testMaxFlowCountEnforced` — лимит `maxFlows` соблюдается.
- [ ] 94. EDGE: `testFlowExhaustionRejectsNewFlowCleanly` — на границе лимита → clean error.
- [ ] 95. `testMemoryPressureNotificationDegrades` — `didReceiveMemoryWarning` → сокращение буферов.
- [ ] 96. `testFrameQueueBoundedByMemory` — очередь имеет байт-потолок.
- [ ] 97. EDGE: `testBackpressureStopsProducing` — `FlowRouter` не принимает новые флоу при переполнении.
- [ ] 98. EDGE: `testZeroLengthReadSurvives` — EOF не бесконечный цикл.
- [ ] 99. INT: `testTransportLostTellsStateMachine` — `SSHTransportSession.channelInactive` → `lostConnection`.
- [ ] 100. INT: `testStopDuringPendingTransmit` — `stop()` отменяет pending completion.

## Глава 6. Kill switch и анти-утечки

**Цель**: закрыть «Physical leak/kill-switch proof remains required».

- [ ] 101. RED: `testKillSwitchIncludedInProfile` — `NETunnelProviderProtocol` + route = All.
- [ ] 102. `testNonAllowedTrafficBlockedWhenDisconnected` — при отключении не-разрешённый трафик блокируется (устройство).
- [ ] 103. `testExcludeVPSSystemRoute` — маршрут VPS хоста исключён из туннеля (все resolved IP).
- [ ] 104. EDGE: `testExcludeWildcardIPRange` — исключить /32 и /128, не весь диапазон.
- [ ] 105. RED: `testLeakCheckFailsOnVPSAddress` — пакеты на public IP VPS не идут в туннель (если идут — RED).
- [ ] 106. `testDNSDoesNotLeakToCarrierDNS` — `includeAllNetworks` + DNS через VPS.
- [ ] 107. `testKillSwitchPreserveVPNIfRouteRemoved` — снятие маршрута не прибивает соединение.
- [ ] 108. EDGE: `testCarrierNetworkTransitionKillSwitch` — Wi-Fi→Cellular не создаёт окно утечки.
- [ ] 109. `testReconnectUnderKillSwitchNoLeakWindow` — до readiness туннель не сообщает «connected».
- [ ] 110. EDGE: `testAppKillWhileUpRetainsSockets` — после принудительного kill старый туннель не остаётся активным.
- [ ] 111. `testVpnStateReportedOnlyAfterConnectivity` — инвариант 7: READY только после SSH+gateway+probe.
- [ ] 112. `testLeakPulseDetector` — фоновый «pulse» на эталонный IP при отключении.
- [ ] 113. RED: `testExtendedGraceOnReconnect` — при reconnect допустимо окно до X мс, стейт сохраняется.
- [ ] 114. `testDNSServerOrderPinnedFirstVPS` — порядок DNS фиксирован (проверять ответ).
- [ ] 115. EDGE: `testEmptyAllowedRouteList` — «allow none» → block-all (без утечки).
- [ ] 116. `testIPv6LLUnroutedToVPS` — локальные линковые маршруты не в туннель.
- [ ] 117. INT: `testKillSwitchStateInDiagnostics` — диагностика показывает безопасность стейт-машины.
- [ ] 118. `testConfigPushedUpdatedOnCarrierChange` — Link Conditioner: 100 мс RTT, 30% loss — состояния держатся.
- [ ] 119. EDGE: `testRouteRaceSetupTeardown` — гонка start/stop не оставляет маршрут без матча.
- [ ] 120. INT: `testKillSwitchDiesWithExtensionRestart` — перезапуск расширения восстанавливает правило.

## Глава 7. Физическая верификация iOS (device, NetworkExtension)

**Цель**: закрыть device-only раздел. Автоматизированные ручные чеки в протоколе.

- [ ] 121. `testEntitlementPresentInPacketTunnel` — `PacketTunnel.entitlements` содержит packet-tunnel-provider.
- [ ] 122. `testVpnProfileLoadsOnDevice` — `NETunnelProviderManager` из Xcode-профиля.
- [ ] 123. `testStartFromColdBoot` — устройство только загружено, VPN вкл.
- [ ] 124. `testStartTunnelTimeoutSurface` — ошибка старта видна за <N сек.
- [ ] 125. `testMultipleStartsSequentialSafe` — 3 быстрых старт/стоп.
- [ ] 126. `testExtensionRestartCrashRecovers` — прибить расширение, проверить автопереподключение.
- [ ] 127. `testSleepWakeWhileConnected` — сон 3 мин, wake, клиент подключается снова.
- [ ] 128. `testBackgroundAppSuspendKeepsTunnel` — приложение свёрнуто, туннель жив.
- [ ] 129. `testKillAppKeepsTunnelUntilManagerStop` — ожидаемое поведение: туннель может жить; решение зафиксировано.
- [ ] 130. `testCarrierSwitchNoDropFlight` — Wi-Fi→Cellular/Cellular→Wi-Fi — без ручного ввода.
- [ ] 131. `testAirplaneModeReconnect` — включение после авиарежима — авто-подключение.
- [ ] 132. `testLockScreenKeychainAccess` — Keychain читается в расширении (AccessGroup).
- [ ] 133. `testAppGroupSharedProfile` — синхронизация профиля через App Group на устройстве.
- [ ] 134. `testBackgroundSocketAllowedOnIpad` — iPad-фокус, socket не убит.
- [ ] 135. `testDynamicTypeAndVoiceOver` — VO-сценарий Connect.
- [ ] 136. `testReducedMotion` — анимации отключены.
- [ ] 137. `testDarkLightSwitch` — обе темы.
- [ ] 138. `testLanguagesSurviveRelaunch` — язык после рестарта сохраняется.
- [ ] 139. `testMemoryLeakCycleCheck` — Instruments: leaks = 0 за 15 мин активного VPN.
- [ ] 140. `testBatteryProfileRoughCheck` — ≤1%/мин в медиа-сценарии.

## Глава 8. Интеграционные тесты с реальным VPS (test harness)

**Цель**: «Integration tests with a disposable Linux VPS», TCP/UDP e2e, packet capture, DNS leak.

- [ ] 141. RED: `testHarnessSpinsDisposableVPS` — скрипт создаёт VPS (provider API / docker на CI) с инжектируемым pubkey.
- [ ] 142. `testProbeWaitsForSSHReady` — poll до 10 мин.
- [ ] 143. `testSSHConnectRealVPS` — реальный канал, pinning реального host key.
- [ ] 144. RED: `testGatewayBootstrapOnRealVPS` — python3 идемпотентно.
- [ ] 145. `testTUNBrokerThreeSessionsE2E` — 3 SSH-сессии + ownership broker (настоящий Linux).
- [ ] 146. `testTCPEchoThroughVPS` — lo echo-сервер на VPS: phone→VPS→echo→VPS→phone.
- [ ] 147. `testUDPEchoThroughVPS` — датаграмма туда-обратно.
- [ ] 148. `testHTTPSiteThroughVPS` — открытый сайт через туннель.
- [ ] 149. `testPacketCaptureExitsVPS` — tcpdump на eth0 VPS видит пакеты.
- [ ] 150. `testNoTrafficOnOurIP` — на нашем IP нет пакетов (privacy).
- [ ] 151. `testDNSLeakNegative` — DNS-запросы идут к VPS, внешний DNS их не видит.
- [ ] 152. `testIPv6Path` — VPS с IPv6 — IPv6-пакеты корректны.
- [ ] 153. `testIPv4OnlyVPS` — IPv6-пакеты отбрасываются, IPv4 жив.
- [ ] 154. `testReconnectOverRealNetwork` — поднимаем/опускаем сеть на VPS.
- [ ] 155. `testKillExtensionOnDeviceLoop` — цикл kill → reconnect на реальном устройстве (lab).
- [ ] 156. `testNetworkLinkConditionerProfiles` — 4 профиля (loss/latency/bandwidth).
- [ ] 157. `testCleanupAfterTestSuite` — каждый тест завершается удалением gateway.
- [ ] 158. `testHarnessArchiveForCI` — результат доступен CI; хэш-пины тестовых хостов.
- [ ] 159. `testFailureIsolation` — фейл одного e2e не маскирует другие (junit + labels).
- [ ] 160. `testProbeDataIsObfuscated` — пароли/ключи не логируются в harness logs.

## Глава 9. UI: My Servers и state-управление сервером

**Цель**: V1 «server list» и добавление/редактирование (сегодня только AddServer + ServerCard placeholder).

- [ ] 161. RED: `testServerListEmptyState` — пустой список → onboarding CTA.
- [ ] 162. `testAddExistingServerValidationIP` — IPv4/IPv6 формат.
- [ ] 163. `testAddExistingServerValidationPort` — 1…65535.
- [ ] 164. `testAddServerDuplicateRejected` — дубликат по fingerprint.
- [ ] 165. `testServerStateBadgeTransitions` — `Connecting→Preparing→Testing→Ready`.
- [ ] 166. `testServerStatePersistenceReload` — перезапуск сохраняет список серверов.
- [ ] 167. `testDeleteServerWithConfirm` — подтверждение удаления.
- [ ] 168. `testEditServerUpdatesCreds` — смена пароля/ключа — пере-авторизация.
- [ ] 169. `testServerCardShowsDiagnosticsLink` — переход в `DiagnosticsView`.
- [ ] 170. `testDisconnectOnServerSwitch` — переключение сервера при активном VPN — stop+start.
- [ ] 171. INT: `testServerAddTriggersValidation` — `VPSEnvironmentValidator` из Главы 1.
- [ ] 172. EDGE: `testAddDuringActiveVPNDisallowed` — нельзя менять сервер, пока Connect активен.
- [ ] 173. `testBuyFlowPlaceholderNavigation` — «Купить VPS» ведёт на заглушку до Главы 11.
- [ ] 174. `testExpirationCountdownFormat` — локализованный формат даты на 6 языках.
- [ ] 175. `testExpiredServerLockedWithExtendCTA` — истёкший сервер заблокирован + CTA продления.
- [ ] 176. RED: `testLanguageSwitchImmediatelyUpdatesUI` — `LanguageStore` → перерисовка.
- [ ] 177. `testVoiceOverLabelsServerButtons` — a11y-лейблы.
- [ ] 178. `testErrorExpandableTechnicalDetails` — «технические детали» раскрываются.
- [ ] 179. EDGE: `testVeryLongServerNameTruncates` — обрезка/полный адрес в tooltip.
- [ ] 180. INT: `testAppModelConnectCallsVPNController` — цепочка UI→Controller→Extension.

## Глава 10. VPS Provisioning adapter (Этап 3)

**Цель**: покупка сервера без участия backend-панели (инфраструктура партнёра).

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
- [ ] 192. `testProviderHistorySnapshot` — журнал заказов (основа Expiration/Replace/Extend).
- [ ] 193. `testProviderWebhookEvent` — партнёрский webhook → порядок обработки.
- [ ] 194. `testProviderRequestSigning` — подпись запросов.
- [ ] 195. `testProviderSecretsNeverLogged` — redaction секретов в логах.
- [ ] 196. `testProvisioningStateMachine` — состояния: pending/creating/ready/failed.
- [ ] 197. RED: `testProvisioningThenAutoAddServer` — готовый сервер автоматически добавляется в My Servers.
- [ ] 198. EDGE: `testDuplicateOrderIdGuard` — идемпотентность заказов.
- [ ] 199. `testProviderDeadlineExpiry` — умирает заказ → release.
- [ ] 200. INT: `testProvisioningCancelsOnAppDisconnect` — пользователь вышел из флоу → cancel.

## Глава 11. Backend (Этап 4): лицензии, trial, заказы

**Цель**: «backend licensing, trial, provider API, order management, webhook, server state, encrypted secrets».

- [ ] 201. RED: `testLicenseVerifySignature` — app-лицензия подписана сервером.
- [ ] 202. `testTrialPeriodStartedOnce` — одно устройство / один trial.
- [ ] 203. `testTrialExpiryGrace` — grace-период.
- [ ] 204. `testServerStateEndpoint` — единый источник статуса сервера.
- [ ] 205. `testOrderCrud` — create/read/cancel/replace.
- [ ] 206. `testWebhookSignatureVerification` — HMAC.
- [ ] 207. `testWebhookReplayProtection` — nonce/timestamp.
- [ ] 208. `testWebhookAtLeastOnceIdempotent` — повторная доставка не меняет состояние.
- [ ] 209. `testProviderAbstractionResolver` — map провайдер→API-драйвер.
- [ ] 210. `testEncryptedSecretsAtRest` — шифрование секретов в БД (никогда plaintext).
- [ ] 211. `testRotateEncryptionKey` — ротация ключей без потерь.
- [ ] 212. `testUserDeviceCap` — привязка license к устройству.
- [ ] 213. `testLicenseOfflineGrace` — offline-работа N дней.
- [ ] 214. `testServerReplacementFlow` — replace старого сервера.
- [ ] 215. `testServerExtendFlow` — продление.
- [ ] 216. `testExpiredServerCleanup` — истечение → release + notify.
- [ ] 217. `testAdminPanelReadOnly` — role-контроль панели.
- [ ] 218. INT: `testBackendErrorsSurfaceInApp` — локальная обработка, нет 500-краша.
- [ ] 219. RED: `testProvisioningThenAutoAdd` — интеграция закупки в UI (из Главы 10).
- [ ] 220. `testWebhookDeadLetter` — очередь обработки + повторная попытка.

## Глава 12. In-App Purchase (Этап 6)

**Цель**: покупка сервера, App Store, валюта, restore.

- [ ] 221. RED: `testStoreKitConfigEnums` — продукты: сервер на месяц/год + lifetime app.
- [ ] 222. `testProductFetch` — storefront fetch, пустой/offline — clean error.
- [ ] 223. `testPurchaseFlowReceipt` — успех → originalTransactionId.
- [ ] 224. `testRestorePurchases` — restore — сервер в списке, без двойной оплаты.
- [ ] 225. `testPurchaseServerThenConnectChain` — покупка → provision → auto-add → connect (INT).
- [ ] 226. `testServerRenewalUsesSameVPS` — продление на тот же VPS.
- [ ] 227. `testSubscriptionCancellationGrace` — отмена продления не рвёт текущий срок.
- [ ] 228. `testPaymentFailureSurface` — payment canceled → человекочитаемая ошибка.
- [ ] 229. `testNoBackgroundLeakOnPayment` — выход из StoreKit не пускает в фон.
- [ ] 230. `testLocalReceiptValidation` — StoreKit2 локальная проверка.
- [ ] 231. `testServerSideReceiptValidation` — сервер подтверждает (sandbox/prod switch).
- [ ] 232. EDGE: `testDoubleTapPurchase` — двойной тап — один транзакционный процесс.
- [ ] 233. `testPurchaseDuringProvisioning` — гонка order↔purchase.
- [ ] 234. `testSandboxReceiptNeverInProd` — изоляция environment.
- [ ] 235. `testNoPromoInSandboxAccident` — sandbox-флаг гасится в проде.
- [ ] 236. `testLocalePriceString` — 6 локалей, форматирование валют.
- [ ] 237. `testExpirationDateAccuracy` — даты истечения по транзакциям.
- [ ] 238. `testOfflinePurchaseHang` — отсутствие сети → clear error.
- [ ] 239. INT: `testPurchaseBlockedWhileNoBackend` — без backend — purchase placeholder.
- [ ] 240. `testRefundWebhookGrantsRefund` — refund-вебхук → разблокировка, откат сервера.

## Глава 13. App Store / Privacy compliance и TestFlight (Этап 8)

**Цель**: «App Store review and VPN privacy compliance review».

- [ ] 241. `testPrivacyPolicyReviewed` — VPN privacy policy: трафик только через пользовательский VPS.
- [ ] 242. `testPresenceInManifest` — App Privacy: типы данных, purpose strings.
- [ ] 243. `testVPNPurposeString` — локализованный usage description.
- [ ] 244. `testNoServerLoggingImpact` — сервер не логирует контент.
- [ ] 245. `testKeychainEntitlementExplicit` — нет лишних entitlements.
- [ ] 246. `testDataUseDeclarationsForNSPrivacy` — `NSPrivacyAccessedAPITypes`.
- [ ] 247. `testTestFlightDistributionMetrics` — crashlytics/analytic pipeline (с permission).
- [ ] 248. `testTestFlightBetaInviteForCarriers` — разные операторы/страны.
- [ ] 249. `testAssertNoThirdPartySDK` — список зависимостей только SwiftNIO (Apache-2.0).
- [ ] 250. `testLicenseComplianceFiles` — LICENSE notices в bundle.
- [ ] 251. `testOptOutOfDeviceDiagnostics` — выключаемый телеметрический канал (ТЗ §33).
- [ ] 252. `testAndroidStoreSplit` — (Этап 7) отдельный трек, изоляция.
- [ ] 253. `testAppReviewReadinessDoc` — пресс-кит для ревьюера: что делает VPN.
- [ ] 254. `testNoProhibitedContent` — формулировки «навсегда бесплатный» исключены (risk).
- [ ] 255. `testBuyVPSFlowNotForbiddenByApple` — покупка сервера — внешний компонент: ToS.
- [ ] 256. `testTwoAccountLimitsGraceful` — обработка «account already exists».
- [ ] 257. `testGDPRDeleteRequest` — экспорт+удаление данных.
- [ ] 258. `testKeyRetentionPolicy` — срок хранения ключей, документ.
- [ ] 259. `testReviewRejectionDrill` — обратный анализ причин реджекта.
- [ ] 260. `testMetadataLocalized` — приложение/скриншоты/описания на 6 языках.

## Глава 14. CI: libFuzzer, покрытие, пайплайн

**Цель**: «libFuzzer/long-running fuzz job remains a CI hardening task».

- [ ] 261. RED: `testCIBuildGreen` — пакет собирается на CI (несколько платформ).
- [ ] 262. `testCoverageGate70` — ≥70% покрытие на unit-global.
- [ ] 263. `testCoverageGate60NewCode` — ≥60% покрытие на новый код (строго).
- [ ] 264. `testSwiftFuzzIntegration` — fuzz-джоба запускается nightly.
- [ ] 265. `testFuzz30MinutesNoCrash` — 30 мин fuzz, 0 crash.
- [ ] 266. `testFuzzFindingsTriaged` — triage-воркфлоу: red → fix → re-fuzz.
- [ ] 267. `testDeterministicCorpusKept` — корпус кадров хранится в репо.
- [ ] 268. `testRegressionCorpusAutomated` — найденный случай добавляется в корпус (RED-first).
- [ ] 269. `testGatewayPythonMypyStrict` — типизация gateway (строгий режим).
- [ ] 270. `testGatewayRuffLintGate` — lint-гейт.
- [ ] 271. `testXcodeBuildBotGreen` — сборка Xcode-проекта (команда из README) в CI.
- [ ] 272. `testStorageAge` — параллельный запуск тестов (XCTest parallel) без race.
- [ ] 273. `testCIArtefactSigned` — артефакты сборки подписаны.
- [ ] 274. `testNightlyIntegrationTag` — nightly-метка e2e/VPS.
- [ ] 275. `testCoverageRegressionCheck` — покрытие не падает к предыдущему прогону.
- [ ] 276. `testMutationKillRateBaseline` — ≥20% mutation kill (цель 40%).
- [ ] 277. `testStaticAnalyzerClean` — swift-analyzer без findings.
- [ ] 278. `testFastFeedback` — unit < 60 с.
- [ ] 279. `testCrashReporterOnCI` — CI собирает crash-лог хараса.
- [ ] 280. `testReleasePipeline` — tag → build → sign → TestFlight.

## Глава 15. Multi-hop (Этап 9)

**Цель**: туннель через VPS1→VPS2 (ТЗ §50).

- [ ] 281. RED: `testChainConfigVPS1VPS2` — профиль с двумя хопами.
- [ ] 282. `testChainHandshakePipelined` — аутентификация хопов последовательна.
- [ ] 283. `testChainSSHToVPS2ThroughVPS1` — SSH jump (ProxyJump-эквивалент).
- [ ] 284. `testChainIdempotentTeardown` — удаление цепочки атомарно.
- [ ] 285. `testSecondHopFailureKillsChain` — падение VPS2 → видимая ошибка.
- [ ] 286. `testFirstHopSurvivesSecondReconnect` — восстановление VPS2 не рвёт VPS1.
- [ ] 287. `testChainLatencyBudget` — суммарный лимит на цепочку (n×lat).
- [ ] 288. `testNoSingleIPOverlap` — исключение маршрутов обеих VPS.
- [ ] 289. `testIPv6MixedChain` — v4 на первом, v6 на втором.
- [ ] 290. `testKillSwitchAppliedPerHop` — при отключении ни один хоп не утекает.
- [ ] 291. `testDiagnosticShowsEachHop` — `DiagnosticsView` — статусы hop 1/2.
- [ ] 292. `testHopCredsInKeychainSeparate` — две учётки, две записи.
- [ ] 293. `testChainCleanupOnAvail` — удаление резервного пути при смерти цепочки.
- [ ] 294. `testMultiHopNoPublicListener` — ни один гейт не слушает публично.
- [ ] 295. `testChainReconnectBounded` — bounded backoff на каждый хоп.
- [ ] 296. `testHopSwapMidSession` — замена VPS2 на лету — новые streamIDs.
- [ ] 297. EDGE: `testZeroHopConfigRejected` — цепочка без хопов отклонена.
- [ ] 298. INT: `testUIOnlyShowsChainWhenMultiConfig` — UI не показывает chain без профиля.
- [ ] 299. `testAnalyticsNoHopIPs` — телеметрия не содержит IP хопов.
- [ ] 300. EDGE: `testChainTimeoutExtremum` — таймаут всей цепочки ограничен сверху.

## Глава 16. TLS transport (Этап 10)

**Цель**: альтернативный транспорт 443, собственный протокол поверх TLS (ТЗ §48, §49).

- [ ] 301. RED: `testTLSHandshakeCustomProtocol` — ALPN-экстеншен.
- [ ] 302. `testTLSCertValidation` — chain против собственного CA.
- [ ] 303. `testMutualAuthPresent` — клиентский сертификат при необходимости.
- [ ] 304. `testReplayProtectionTLS` — nonce/timestamp.
- [ ] 305. `testSessionAuthDerivedKeys` — ключи сессии из handshake.
- [ ] 306. `testRateLimitProtection` — лимит на соединение.
- [ ] 307. `testUnauthorizedRelayPrevention` — «не наш клиент» отвергнут.
- [ ] 308. `testNoTrafficStorage` — сервер не хранит пользовательский трафик.
- [ ] 309. `testRouteDataPlaneParallelsSSH` — тот же каркас, что SSH (общий интерфейс).
- [ ] 310. `testFallbackToSSH` — TLS недоступен → SSH (обратная совместимость).
- [ ] 311. `testPinCheckOnCertificate` — запасной pin для защиты.
- [ ] 312. `testPerformanceSSHvsTLSBaseline` — benchmark / VPN latency.
- [ ] 313. `testTLSThroughCaptiveProxy` — за прокси работает.
- [ ] 314. `testTLSBehindFirewall` — режим firewall block.
- [ ] 315. `testUpgradePathTrigger` — включается через «экспертную» настройку.
- [ ] 316. `testTLSOverCellularMetric` — battery/perf сравнительный отчёт.
- [ ] 317. `testNoObfuscationPromise` — не обещать «неотличим от HTTPS» (ТЗ §48).
- [ ] 318. `testCryptoBudget` — min cryptography 2026: TLS 1.3, AEAD.
- [ ] 319. INT: `testTLSHandshakeReusesSessionLogic` — `SessionHandshake` пригодна для обоих транспортов.
- [ ] 320. `testABTestGate` — A/B: SSH vs TLS включение через конфигурацию.

---

# Часть B. Причинно-следственные цепочки функций + тесты

Принцип: каждая цепочка — «если вызов A, то при условии B производится C, что влияет на D». Для каждой — тест на красном, крайние случаи, проверка ответа и взаимодействия.

## C1. Подключение: Connect → system VPN

**Цепочка:** `AppModel.connect` → `VPNController.start` → `PacketTunnelProvider.startTunnel` → `SSHEndpointResolver.resolve` → `SSHTransportFactory.connect` → `SessionHandshake.accept` → `GatewayCommandBuilder.pythonInline` → `Gateway.run` (stdin/stdout) → `RawPacketBridge.outboundFrame` → `SSHTransportSession.send` → `packetFlow`.

- [ ] Тест (RED): mock transport + локальный python-гейт: весь путь до виртуального «connected»; без реализации одного из звеньев фейл на handshake.
- [ ] EDGE: несуществующий хост; zero-length host; порт 0; payload на границе лимита; повторный connect при активном (идемпотентность); таймаут каждого звена.
- [ ] INT/Ответ: после каждого шага проверить стейт `TunnelStateMachine`, буфер `RawPacketBridge`, реально отправленный frame в `SSHFrameCodec.write`.

## C2. Кадровый протокол: encode → decode → codec → handshake

**Цепочка:** `TransportFrame.encoded` → `TransportFrameDecoder.append` → `SSHFrameCodec` (фрагментация SSH) → `SessionHandshake.accept` → `FlowRouter.transport`.

- [ ] Тест (RED): round-trip потока фреймов через фрагментацию (1 байт за раз) с валидным handshake.
- [ ] EDGE: пустой payload / payload==MAX / MAX+1; reserved bits≠0; unknown version/type; длина объявлена, а реальных байтов нет; несколько фреймов в одном read; битый второй фрейм после валидного первого.
- [ ] INT/Ответ: ошибка декодера не «зарубает» другой поток → `FlowRouter` назначает другой transport, счётчик ошибок растёт.

## C3. Аутентификация и replay-защита

**Цепочка:** `SessionHandshake.accept(HELLO(stream=0,nonce))` → гейт отвечает → `accept(ACK)` exact → `TunnelStateMachine.connected()`; неправильный nonce / ACK после ACK / ACK на stream≠0 → error state.

- [ ] Тест (RED): exact ACK принимается ровно один раз, затем отвергается (replay).
- [ ] EDGE: wrong nonce; wrong order; ACK до HELLO; data до ACK; большой повтор nonce; ACK на stream 0 и 1.
- [ ] INT/Ответ: `LockedSessionHandshake.accept` (App-обёртка) проксирует в `VPNCore.SessionHandshake`; unit-тест на реальном `LockedSessionHandshake`.

## C4. Пиннинг host key → safe-fail

**Цепочка:** `SSHTransportFactory.connect` (hostKeyPinned) → смена ключа → `PinnedHostKeyDelegate.validateHostKey` → fail → `ConnectionStateMachine.fail(.authentication)`.

- [ ] Тест (RED): поднять локальный SSH с первым ключом, перезапустить со вторым → reject.
- [ ] EDGE: wrong password; port closed; host not resolvable; timeout; missing python → `gatewayMissing`; rate-bound probe.
- [ ] INT/Ответ: failure → ошибка в UI без авто-retry (только действие пользователя).

## C5. Raw-пакетный мост и NAT-оборот

**Цепочка:** `IPPacket.parse` (IPv4/IPv6) → `RawPacketBridge.outboundFrame` (stream 0, raw type) → `Gateway.open_tun_device`/`configure_tun` → NAT → return → `RawPacketBridge.inboundPacket` → `packetFlow`.

- [ ] Тест (RED): e2e harness (Глава 8) — пакет уходит из VPS (tcpdump), возвращается и доставлен `PacketTunnelPacketLoop`.
- [ ] EDGE: truncated IPv4; totalLength < header; totalLength > payload; версия ≠4/6; stream≠0 в raw → reject; oversized MBU.
- [ ] INT/Ответ: outbound↔inbound — идентичность данных и отсутствие потери на TUN-обратном loop.

## C6. Реконнект: транспорт умер → перестройка без утечки streamID

**Цепочка:** `SSHTransportSession.channelInactive` → `ConnectionStateMachine.lostConnection(attempt)` → backoff (`ReconnectPolicy.delay`, bounded) → новый `SSHTransportFactory.connect` → новый HELLO/ACK → `FlowRouter` не переиспользует старые streamID.

- [ ] Тест (RED): transport A убит → reconnect сохраняет «explicit attempt»; новый сеанс ждёт новых ID (до фикса — старые ID переиспользуются → RED).
- [ ] EDGE: attempt=0/1/MAX/MAX+1 (delay=0, без jitter, отрицательных нет); reconnect при stop — не реконнект; параллельные reconnect — один активный; jitter в [0,1) bounds.
- [ ] INT/Ответ: очередь пакетов при «transport lost» не роняет кадры других живых transport; broker ownership (Глава 8) пересоздаётся.

## C7. Flow mode TCP/UDP: half-close и idle-expiry

**Цепочка:** flow открыт → `Gateway.open_tcp/open_udp` → DATA → FIN → half-close (пишется только write-window) → idle > timeout → `Gateway.expire_idle_flows` закрывает → `FlowRouter.close`.

- [ ] Тест (RED): e2e echo: FIN → half-close не рвёт read side; idle-expiry закрывает.
- [ ] EDGE: idle=0 (сразу); большой idle; отказ fdle; окно закрыто с обеих сторон; FIN когда flow уже закрыт — идемпотентно; FIN на raw-потоке (недопустим) → error.
- [ ] INT/Ответ: `FlowRouter.close` освобождает транспорт для новых flow; backpressure упорядочен.

## C8. Kill switch / маршруты

**Цепочка:** `SSHEndpointResolver.resolve` (все IPv4/IPv6) → исключены из туннеля (anti-recursion) → `TunnelConfiguration` → profile route → READY только после probe.

- [ ] Тест (RED): на устройстве: пакет на IP VPS гарантированно вне туннеля; leak-детектор при «connected»=false.
- [ ] EDGE: hostname с A+AAAA (оба исключены); wildcard /32; CIDR-подстановка; 0 адресов (fail-closed); IPv6 LL не в туннель; порядок DNS.
- [ ] INT/Ответ: смена сети (Wi-Fi↔LTE) → route-правило не потеряно.

## C9. Bootstrap готовности → диагностика

**Цепочка:** `VPSEnvironmentValidator` → `GatewayCommandBuilder.pythonInline` → поднят гейт → probe (TCP к внешнему хосту) → READY → `ConnectionStateMachine.connected` → `DiagnosticsView` показывает результат.

- [ ] Тест (RED): гейт не поднят → никогда READY; probe fail → state testing→failed (`failed(.gatewayUnavailable)`).
- [ ] EDGE: probe timeout; отсутствие сети на VPS; 404 от внешнего хоста; превышение retry.
- [ ] INT/Ответ: fail до READY → UI не показывает «connected»; серверный badge → failed (Глава 9, п.165).

## C10. Бинарь и подпись → запуск → cleanup

**Цепочка:** sha256 → Ed25519 verify → временный файл `0700` → execute → при exit/error → delete.

- [ ] Тест (RED): подписанный бинарь исполняется; tampered → reject; exit → файл удалён.
- [ ] EDGE: подпись валидна, но файл битый; права ровно 0700; нет прав на tmpdir; нехватка места; kill процесса → cleanup при следующем проходе.
- [ ] INT/Ответ: install mode → файл переживает рестарт, но сигнатура обязательна; remove mode → файла нет.

## C11. Sleep/wake и suspension

**Цепочка:** `PacketTunnelProvider.sleep` → `PacketTunnelPacketLoop.suspend` → стоп чтения/кадра; `wake` → `resume` → восстановление очереди/соединения.

- [ ] Тест (RED): очередь suspend: frames не уходят, порядок сохранён после resume; сон > лимита → полный цикл reconnect.
- [ ] EDGE: suspend при отключении (no-op); двойной resume; прерванный send из suspend; stop во время suspend.
- [ ] INT/Ответ: `TunnelStateMachine` не видит «connected» при suspend → UI честный «reconnecting».

## C12. Покупка → Provision → Auto-add → Connect (меж-сервисная гонка)

**Цепочка:** `StoreKit2.purchase` → `Order` → `Provider.createOrder` → `Poll states` → ready → credentials (Keychain) → `ServerStore.add` → `AppModel.connect(server)`.

- [ ] Тест (RED): весь путь покупки с mock-провайдером заканчивается Connected; любой облом → `OrderState.failed` и кнопка «Исправить».
- [ ] EDGE: покупка успешна, но provisioning fails; два заказа параллельно; двойной тап; повторный connect сразу после ready; истечение подписки.
- [ ] INT/Ответ: сервер появляется в списке только после auto-add; UI не даёт Connect на pending.

## C13. Reconnect ↔ Kill switch ↔ Network transitions (кросс-цепочка)

**Цепочка:** сеть меняется → teardown → (Kill switch активен) → без утечки → reconnect → новые streamIDs → READY.

- [ ] Тест (RED): на устройстве: смена Wi-Fi↔LTE при активном VPN — ни одного пакета в обход (leak-сниффер), сессия пересоздана.
- [ ] EDGE: LTE без интернета (dead interface); переход mid-reconnect; airplane-режим; рестарт сети.
- [ ] INT/Ответ: `TunnelStateMachine` и `PacketTunnelPacketLoop` согласованы во времени (UI «connected» = фактическое состояние).