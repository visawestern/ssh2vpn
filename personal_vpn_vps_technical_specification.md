# Техническое задание
## Персональный VPN-клиент через собственный VPS

**Версия:** 1.0  
**Дата:** 28 августа 2026  
**Статус:** концепция для разработки и дальнейшего технического аудита

---

# 1. Назначение продукта

Приложение предоставляет обычному пользователю простой способ получить системный VPN на телефоне, используя:

1. уже имеющийся у пользователя VPS с SSH-доступом;
2. либо VPS, купленный непосредственно через приложение по модели партнёрского/reseller provisioning.

Ключевая идея продукта:

> Пользователь не обязан понимать, что такое VPS, SSH, IP-адрес, маршрутизация или настройка VPN. Он должен получить работающий персональный VPN максимально коротким путём.

Приложение **не является классическим VPN-провайдером** и не предоставляет собственную сеть VPN-серверов. Трафик пользователя должен проходить непосредственно между устройством пользователя и его сервером.

---

# 2. Бизнес-модель

## 2.1. Приложение

Модель:

- единоразовая покупка;
- ориентировочная цена: **$9.99**;
- подписки на само приложение нет;
- после покупки приложение используется без ежемесячной оплаты лицензии.

### Бесплатный период

Предусмотреть конфигурируемый trial-период для проверки работоспособности приложения.

Рекомендуемое значение на старте:

- 30 дней.

Trial должен позволять полноценно протестировать основную функцию подключения.

---

# 3. VPS как отдельный продукт

VPS не является подпиской на приложение.

Пользователь покупает сервер на конкретный срок:

- 1 месяц;
- 3 месяца;
- 6 месяцев;
- 12 месяцев.

При большем сроке цена за месяц может быть ниже.

Пример:

```text
1 month     $4.99
3 months    $13.49
6 months    $24.99
12 months   $39.99
```

Фактические цены должны приходить от выбранного инфраструктурного партнёра.

## 3.1. Жизненный цикл сервера

Если пользователь купил сервер на 1 месяц:

```text
purchase
    ↓
server created
    ↓
active
    ↓
expiration date
    ↓
expired
```

После истечения оплаченного срока сервер не должен продолжать существовать за счёт нашей инфраструктуры.

В зависимости от возможностей партнёра:

- сервер удаляется;
- либо переводится в состояние expired и удаляется после grace period.

Автоматическое продление без явного действия пользователя не является частью базовой модели.

---

# 4. Основная пользовательская проблема

Большинство обычных пользователей не умеют:

- выбирать VPS;
- регистрироваться у cloud-провайдера;
- выбирать подходящую конфигурацию;
- понимать разницу между VPS и VPN;
- находить IP сервера;
- находить SSH username;
- находить SSH password/key;
- понимать порт SSH;
- переносить эти данные в VPN-клиент;
- диагностировать ошибки подключения.

Поэтому приложение должно скрывать техническую инфраструктуру.

Пользователь должен воспринимать VPS как:

> **мой VPN-сервер**

а не как отдельную техническую сущность.

---

# 5. Основные пользовательские сценарии

## 5.1. Пользователь уже имеет VPS

```text
Install
  ↓
Trial
  ↓
Add existing server
  ↓
IP / hostname
Username
Password или SSH key
  ↓
Test connection
  ↓
Configure tunnel
  ↓
Connect
```

## 5.2. Пользователь не имеет VPS

```text
Install
  ↓
Get VPN Server
  ↓
Choose location
  ↓
Choose duration
  ↓
Choose price/tariff
  ↓
Purchase
  ↓
Provisioning
  ↓
Server ready
  ↓
Automatically added to My Servers
  ↓
Connect
```

Цель UX:

> От покупки сервера до возможности нажать Connect без ручного поиска IP, логина, пароля и SSH-настроек.

---

# 6. Главный экран

Пример:

```text
Personal VPN

┌──────────────────────────────┐
│                              │
│       ● Disconnected         │
│                              │
│       Singapore              │
│                              │
│        [ CONNECT ]           │
│                              │
└──────────────────────────────┘

My Servers

🇸🇬 Singapore
Active
Expires: 27 Sep 2026

[ Manage ]

+ Add Existing Server
+ Buy VPN Server
```

Если серверов нет:

```text
Personal VPN

No VPN server

[ BUY VPN SERVER ]

or

[ ADD EXISTING SERVER ]
```

---

# 7. Раздел My Servers

Каждый сервер должен иметь:

- название;
- страну;
- IP/hostname, скрытый или вторичный для обычного пользователя;
- статус;
- дату окончания;
- срок действия;
- источник сервера:
  - Existing;
  - Purchased;
- подключён/отключён;
- latency;
- последнее успешное подключение;
- состояние SSH;
- состояние VPN.

Пример:

```text
🇸🇬 Singapore

● Ready

Expires:
27 Sep 2026

Latency:
42 ms

[ CONNECT ]
```

---

# 8. Покупка VPN-сервера

## 8.1. Выбор страны

Пользователь выбирает понятное название:

```text
🇸🇬 Singapore
🇯🇵 Japan
🇺🇸 United States
🇬🇧 United Kingdom
🇩🇪 Germany
...
```

Количество стран определяется доступностью инфраструктурных партнёров.

## 8.2. Выбор тарифа

Приложение должно показывать:

- срок;
- итоговую цену;
- эквивалентную цену за месяц;
- дату окончания.

Пример:

```text
1 month
$4.99

3 months
$13.49
$4.50/month

6 months
$24.99
$4.17/month

12 months
$39.99
$3.33/month
```

## 8.3. Выбор провайдера

Провайдер не должен быть основным пользовательским понятием.

Backend самостоятельно выбирает инфраструктурного партнёра по:

1. стране;
2. доступности;
3. цене;
4. скорости provisioning;
5. техническим требованиям;
6. марже;
7. качеству инфраструктуры.

В будущем допускается агрегирование нескольких провайдеров.

---

# 9. Provisioning

После покупки сервер создаётся автоматически.

Логика:

```text
User purchase
      ↓
Backend receives order
      ↓
Select provider
      ↓
Create VPS
      ↓
Wait for provisioning
      ↓
Wait for SSH
      ↓
Install/configure required components
      ↓
Test SSH
      ↓
Test tunnel
      ↓
Mark server READY
      ↓
Return server configuration
      ↓
App displays server
```

Целевой UX:

> Сервер появляется в My Servers автоматически через минимально возможное время.

Целевой показатель:

- желательно 10–30 секунд;
- допустимый fallback: несколько минут с понятным прогрессом.

Приложение не должно зависать на экране загрузки без объяснения происходящего.

---

# 10. Backend

Backend необходим для:

- лицензирования приложения;
- trial;
- provisioning;
- интеграции с VPS-провайдерами;
- управления заказами;
- получения состояния серверов;
- обработки expiration;
- webhook обработки;
- выбора провайдера;
- расчёта цены;
- защиты API;
- диагностики provisioning.

Backend **не должен быть транзитным маршрутом пользовательского VPN-трафика**.

То есть:

```text
Phone
  │
  │ VPN traffic
  ▼
User VPS
  │
  ▼
Internet
```

а не:

```text
Phone
  ↓
Our VPN server
  ↓
User VPS
  ↓
Internet
```

---

# 11. Хранение пользовательских данных

Основной принцип:

> Минимизировать данные, которые проходят через нашу инфраструктуру.

## 11.1. На устройстве

Чувствительные данные:

- SSH password;
- private key;
- authentication material;
- локальная конфигурация tunnel;

хранятся в защищённом системном хранилище:

- iOS Keychain;
- Android Keystore / encrypted storage.

## 11.2. На backend

Хранить только данные, необходимые для:

- лицензии;
- provisioning;
- биллинга;
- состояния VPS;
- поддержки;
- восстановления состояния заказа.

Не хранить:

- историю посещённых сайтов;
- содержимое трафика;
- DNS history;
- URL;
- пользовательские запросы;
- VPN packet logs.

---

# 12. VPN-архитектура

## 12.1. iOS

Использовать системный механизм:

**Network Extension / NEPacketTunnelProvider.**

Архитектура:

```text
iOS App
   │
   ├── UI
   ├── Server management
   └── Configuration
          │
          ▼
NEPacketTunnelProvider
          │
          ▼
SSH-based transport
          │
          ▼
User VPS
```

Трафик должен быть представлен системе как полноценный VPN-интерфейс.

Нельзя ограничиваться SOCKS5 proxy, если продукт позиционируется как system-wide VPN.

## 12.2. Android

Использовать:

**VpnService**

для создания системного VPN-интерфейса.

Архитектура должна соответствовать iOS по пользовательскому поведению:

```text
Application
     ↓
System VPN interface
     ↓
SSH tunnel
     ↓
User VPS
     ↓
Internet
```

---

# 13. SSH-транспорт

Основной транспорт продукта:

> SSH.

Цель:

- пользовательский VPS не требует установки полноценного VPN-сервера;
- приложение само устанавливает SSH-соединение;
- приложение самостоятельно создаёт VPN tunnel поверх SSH;
- пользователь не должен запускать `ssh -D`;
- SOCKS5 не должен быть основной архитектурой.

Необходимо исследовать и выбрать реализацию полноценного IP-туннеля поверх SSH.

Варианты реализации должны быть проверены отдельно:

1. собственный transport;
2. SSH channel + userspace packet forwarding;
3. tun/tap abstraction;
4. потоковый multiplexing;
5. TCP/UDP forwarding;
6. существующая библиотека SSH с необходимыми лицензиями.

Выбор конкретного механизма производится после прототипа и нагрузочного тестирования.

---

# 14. Требования к туннелю

Базовая версия должна поддерживать:

- TCP;
- UDP;
- IPv4;
- IPv6;
- DNS;
- full-device routing;
- reconnect;
- connection timeout;
- graceful disconnect;
- tunnel health check.

Цель:

```text
iPhone
   ↓
all traffic
   ↓
VPN tunnel
   ↓
SSH
   ↓
VPS
   ↓
Internet
```

---

# 15. DNS

Предусмотреть два режима:

## 15.1. DNS через VPS

```text
Phone
 ↓
VPN
 ↓
VPS DNS resolver
```

## 15.2. Пользовательский DNS

В настройках можно позволить выбрать DNS resolver.

Базовый режим должен быть максимально простым.

---

# 16. Kill Switch

Предусмотреть защиту от утечки трафика при разрыве туннеля.

Желаемое поведение:

```text
VPN connected
     ↓
Traffic allowed

VPN disconnected
     ↓
Traffic blocked
```

На каждой платформе необходимо использовать доступные системные механизмы.

---

# 17. Автоматическое переподключение

При:

- потере Wi-Fi;
- переходе Wi-Fi → cellular;
- переходе cellular → Wi-Fi;
- кратковременном разрыве SSH;
- изменении сети;

приложение должно автоматически восстанавливать соединение.

Алгоритм:

```text
connection lost
      ↓
detect
      ↓
reconnect
      ↓
verify tunnel
      ↓
restore routing
```

Должна существовать защита от бесконечного цикла быстрых reconnect.

Использовать backoff.

---

# 18. SSH-аутентификация

Поддержать:

### Password

```text
Host
Port
Username
Password
```

### SSH private key

Поддержать импорт ключа из системных источников.

### В будущем

- encrypted private key;
- passphrase;
- hardware-backed key storage;
- дополнительные SSH authentication methods.

---

# 19. Добавление существующего сервера

Форма должна быть максимально простой:

```text
Add Server

Server address
[________________]

Username
[________________]

Password
[________________]

SSH Port
[ 22 ]

[ TEST CONNECTION ]
```

Расширенные параметры должны быть спрятаны в Advanced.

Не показывать пользователю сложную SSH-конфигурацию без необходимости.

После успешного теста:

```text
✓ SSH connection successful

✓ Tunnel supported

[ SAVE SERVER ]
```

---

# 20. Диагностика

Ошибки должны быть человеческими.

Вместо:

```text
ECONNREFUSED
```

показывать:

```text
Unable to connect to the server.

Possible causes:
• server is offline
• SSH port is blocked
• incorrect credentials
• network unavailable

[ TEST AGAIN ]
[ DETAILS ]
```

В Details можно показать техническую информацию для продвинутого пользователя.

---

# 21. Multi-hop

Функция второго этапа.

Пользователь должен иметь возможность построить:

```text
Phone
  ↓
VPS A
  ↓
VPS B
  ↓
Internet
```

или:

```text
Phone
  ↓
Singapore
  ↓
Japan
  ↓
USA
  ↓
Internet
```

UX:

```text
My Servers

🇸🇬 Singapore
      ↓
🇯🇵 Japan
      ↓
🇺🇸 USA

[ CONNECT ]
```

Добавление узла:

```text
[ + Add Server ]
```

Никакого ручного редактирования SSH-команд.

---

# 22. Управление сроком сервера

Для купленного сервера:

```text
🇸🇬 Singapore
Active

Expires:
27 Sep 2026

[ Extend ]
[ Replace ]
[ Delete ]
```

## Extend

Продление существующего VPS на новый срок.

## Replace

Создание нового VPS.

После создания нового сервера:

1. новый VPS проверяется;
2. новый tunnel проверяется;
3. новый сервер появляется в My Servers;
4. пользователь может подключиться;
5. старый VPS может быть удалён.

---

# 23. Expiration

До окончания:

```text
Expires in 7 days
```

Показать предупреждение.

Например:

```text
Your VPN server expires in 7 days.

[ EXTEND ]
```

За 3 дня:

```text
Your server expires in 3 days.
```

После окончания:

```text
Server expired

[ BUY NEW SERVER ]
```

Никакого автоматического списания без явного действия пользователя.

---

# 24. Покупка сервера и App Store / Google Play

Платёжная архитектура должна проектироваться отдельно для каждой платформы и региона.

Нельзя заранее считать, что любая покупка VPS внутри мобильного приложения автоматически проходит через систему покупки приложения.

Необходимо классифицировать VPS как отдельную инфраструктурную услугу и соблюдать актуальные правила соответствующего магазина приложений.

На момент реализации необходимо проверить актуальные:

- Apple App Store Review Guidelines;
- Apple payment rules;
- external purchase rules;
- Google Play Billing rules;
- региональные исключения;
- правила для cloud/hosting services;
- правила отображения внешнего checkout.

До получения юридически и технически подтверждённой схемы не реализовывать обход платежных механизмов магазина.

---

# 25. Партнёрская инфраструктура

Требования к VPS-партнёру:

1. API provisioning.
2. API создания VPS.
3. API удаления VPS.
4. API получения IP.
5. API получения состояния сервера.
6. API billing/order management.
7. Webhooks.
8. White-label/reseller возможность.
9. Предсказуемая wholesale-маржа.
10. Возможность масштабирования.
11. Хорошая география.
12. Быстрый provisioning.
13. Возможность автоматической работы без ручного вмешательства конечного пользователя.

Приоритет:

> **Reseller / wholesale margin > affiliate commission.**

Причина:

reseller-модель даёт возможность контролировать retail price и маржу и не зависит от cookie attribution.

---

# 26. Провайдерская абстракция

Backend не должен быть жёстко привязан к одному VPS-провайдеру.

Создать интерфейс:

```text
VpsProvider
```

С операциями:

```text
listRegions()
listPlans()
getQuote()
createCustomer()
createServer()
getServer()
getServerCredentials()
getServerStatus()
getServerIp()
deleteServer()
extendServer()
cancelServer()
```

Каждый провайдер реализует собственный adapter:

```text
UpCloudProvider
Time4VpsProvider
ProviderB
ProviderC
```

Внутренняя бизнес-логика работает через общий интерфейс.

---

# 27. Router выбора провайдера

Backend получает:

```text
country
duration
plan
availability
```

и выбирает оптимальный источник.

Пример:

```text
Singapore

Provider A
cost: $3.20
provision: 20 sec
margin: 30%

Provider B
cost: $3.00
provision: 90 sec
margin: 20%
```

Можно выбрать Provider A из-за скорости и большей маржи.

Алгоритм должен быть конфигурируемым.

---

# 28. Безопасность provisioning

Особенно важно:

- credentials не должны попадать в обычные логи;
- password/private key не должен записываться в application logs;
- credentials передаются по TLS;
- backend secrets хранятся в secret manager;
- provider API keys никогда не отправляются клиенту;
- серверные credentials должны иметь минимально необходимые права;
- provisioning API должен иметь rate limiting;
- защита от массового создания VPS;
- защита от злоупотребления trial;
- аудит административных операций.

---

# 29. Backend API

Пример:

```text
POST /api/v1/auth/device
POST /api/v1/license/activate
GET  /api/v1/license

GET  /api/v1/servers
POST /api/v1/servers
GET  /api/v1/servers/{id}
DELETE /api/v1/servers/{id}

GET  /api/v1/vps/regions
GET  /api/v1/vps/plans
POST /api/v1/vps/quote
POST /api/v1/vps/orders

POST /api/v1/vps/orders/{id}/cancel
POST /api/v1/vps/servers/{id}/extend
POST /api/v1/vps/servers/{id}/replace

GET  /api/v1/diagnostics/{serverId}
```

Названия являются примерными и должны быть уточнены при проектировании API.

---

# 30. Модель данных

## User

```text
id
device_id
created_at
updated_at
```

Не требовать полноценный аккаунт, если это не необходимо.

## License

```text
id
user_id
platform
purchase_id
status
trial_started_at
trial_ends_at
purchased_at
created_at
updated_at
```

## Server

```text
id
user_id
provider_id
provider_server_id
name
country
region
status
source
expires_at
created_at
updated_at
```

## ServerCredentials

```text
server_id
host
port
username
authentication_reference
```

Секретные данные должны храниться отдельно от обычной записи Server и шифроваться.

## Order

```text
id
user_id
provider_id
region
plan
duration
price
currency
status
provider_order_id
provider_server_id
created_at
completed_at
expires_at
```

---

# 31. Лицензирование приложения

Поддержать:

- trial;
- App Store purchase;
- Google Play purchase;
- restore purchase;
- device migration в рамках разрешённых платформой механизмов;
- серверную проверку покупки;
- локальный fallback при временной недоступности backend.

Приложение не должно становиться полностью неработоспособным из-за кратковременной недоступности нашего backend после успешной покупки.

---

# 32. Приватность

Ключевой принцип продукта:

> Мы не предоставляем VPN-трафик через собственные серверы.

Маркетинговое позиционирование должно соответствовать фактической архитектуре.

Не заявлять:

- «невозможно отследить»;
- «невозможно обнаружить»;
- «абсолютная анонимность».

Корректная формулировка:

> Трафик проходит через ваш собственный сервер, а не через VPN-сеть нашего сервиса.

---

# 33. Телеметрия

Минимизировать телеметрию.

Разрешённые технические события:

```text
app_opened
trial_started
purchase_verified
server_created
server_ready
connection_started
connection_failed
connection_succeeded
server_expired
```

Не отправлять:

```text
visited_domains
URLs
DNS queries
packet contents
traffic payload
browsing history
```

IP-адрес сервера не должен попадать в аналитические системы без необходимости.

---

# 34. Монетизация

Основная:

> $9.99 lifetime app purchase.

Вторичная:

> маржа с VPS.

Цель:

```text
Application revenue
+
VPS reseller margin
```

VPS revenue не должен быть обязательным условием окупаемости приложения.

Это означает:

```text
0 VPS sales
      ↓
приложение всё равно имеет бизнес-модель

VPS sales
      ↓
дополнительный recurring revenue
```

---

# 35. Основные конкурентные преимущества

## 35.1. One-click VPS

Пользователь не:

- регистрируется у VPS-провайдера;
- ищет IP;
- ищет пароль;
- изучает SSH;
- копирует credentials.

## 35.2. Собственный сервер

Пользователь получает собственную точку выхода в интернет.

## 35.3. Lifetime app

Нет обязательной подписки на клиент.

## 35.4. Existing VPS support

Продвинутый пользователь может использовать свой VPS бесплатно после покупки приложения.

## 35.5. Multi-provider

В будущем можно выбирать оптимального инфраструктурного партнёра.

## 35.6. Multi-hop

Несколько собственных серверов могут объединяться в цепочку.

---

# 36. UX-принципы

Главное правило:

> **Техническая сложность должна находиться под капотом.**

Пользователь должен понимать только:

```text
VPN
Servers
Country
Price
Expires
Connect
```

А не:

```text
SSH
TUN
SOCKS
KVM
vCPU
RAM
iptables
routing
MTU
TCP forwarding
```

Advanced-раздел допускается для технических пользователей.

---

# 37. Структура приложения

```text
App
├── Home
├── My Servers
│   ├── Server Details
│   ├── Connect
│   ├── Extend
│   ├── Replace
│   └── Diagnostics
├── Buy VPN Server
│   ├── Location
│   ├── Duration
│   ├── Price
│   └── Purchase
├── Add Existing Server
├── Settings
│   ├── DNS
│   ├── Kill Switch
│   ├── Auto Reconnect
│   ├── Routing
│   └── Advanced
└── Help
```

---

# 38. Требования к серверной части VPS

При создании VPS приложение должно обеспечить готовность сервера к SSH-туннелю.

Минимально:

```text
OS
SSH
network
required forwarding components
required tunnel agent/components
```

Если архитектура позволяет работать без дополнительного агента, предпочтительно не устанавливать постоянное ПО.

Если агент необходим:

- установка должна выполняться автоматически;
- версия агента должна контролироваться;
- обновление должно быть автоматизировано;
- агент должен быть минимальным;
- агент не должен собирать пользовательский трафик;
- удаление сервера должно удалять весь наш компонент.

---

# 39. Проверка готовности сервера

Provisioning не считается завершённым после получения статуса `running`.

Необходимы проверки:

```text
VPS running
   ↓
network reachable
   ↓
SSH reachable
   ↓
authentication successful
   ↓
tunnel initialization successful
   ↓
packet forwarding successful
   ↓
external connectivity successful
   ↓
READY
```

Только после этого сервер показывается как готовый.

---

# 40. Состояния сервера

```text
CREATING
PROVISIONING
TESTING
READY
CONNECTING
CONNECTED
DISCONNECTING
OFFLINE
EXPIRING
EXPIRED
DELETING
DELETED
ERROR
```

---

# 41. Состояния заказа

```text
CREATED
PAYMENT_PENDING
PAID
PROVISIONING
READY
FAILED
CANCELLED
REFUNDED
```

---

# 42. Обработка ошибок provisioning

Если VPS создан, но наша настройка не удалась:

1. повторить provisioning;
2. выполнить rollback;
3. при невозможности восстановления удалить сервер;
4. создать replacement при необходимости;
5. не показать пользователю «готовый» сервер, который фактически не работает.

Пользователь должен получить понятный статус:

```text
We couldn't prepare your server.

You were not charged / Your order is being refunded.
```

Фактическая формулировка зависит от платёжной системы.

---

# 43. Скорость

Целевые показатели:

| Операция | Цель |
|---|---:|
| App launch | < 2 sec |
| Existing server SSH test | < 5 sec |
| VPS provisioning | 10–30 sec желательно |
| VPN connect после READY | < 5 sec |
| Reconnect | < 10 sec |
| Server status refresh | < 3 sec |

Фактические показатели зависят от инфраструктурного партнёра.

---

# 44. Производительность туннеля

Требуется измерить:

- throughput;
- latency;
- packet loss;
- CPU VPS;
- CPU телефона;
- RAM;
- battery impact;
- TCP performance;
- UDP performance;
- IPv4;
- IPv6;
- DNS latency.

Тестировать минимум:

```text
Wi-Fi
5G
4G
Wi-Fi → 5G
5G → Wi-Fi
```

---

# 45. Ограничения MVP

В первую версию не включать:

- собственную VPN-сеть;
- собственные VPN-серверы;
- обязательную регистрацию аккаунта;
- социальные функции;
- рекламу;
- сложный enterprise management;
- управление DNS-зонами;
- полноценную панель VPS-хостинга;
- Kubernetes;
- управление произвольными cloud-инстансами.

Главный продукт должен оставаться:

> **простым VPN-клиентом для собственного VPS.**

---

# 46. Версия 1

Обязательные функции:

### Клиент

- системный VPN;
- SSH transport;
- TCP;
- UDP;
- IPv4;
- DNS;
- reconnect;
- kill switch;
- password authentication;
- SSH key;
- existing VPS;
- server list;
- connection diagnostics.

### VPS

- выбор страны;
- выбор срока;
- покупка;
- provisioning;
- автоматическое получение credentials;
- автоматическое добавление сервера;
- expiration;
- replacement;
- extend.

### Backend

- licensing;
- trial;
- provider API;
- provisioning;
- order management;
- webhook;
- server state;
- encrypted secrets;
- provider abstraction.

---

# 47. Версия 1.1

- Multi-hop.
- Более широкий выбор стран.
- Несколько VPS-провайдеров.
- Автоматический выбор лучшего провайдера.
- Split tunneling.
- Более продвинутая диагностика.
- QR/import configuration.
- дополнительные SSH authentication methods.

---

# 48. Версия 2

Исследовать альтернативный transport поверх TLS/HTTPS.

Концепция:

```text
Phone
  ↓
TLS/HTTPS :443
  ↓
User VPS
  ↓
Internet
```

Цель:

- альтернативный transport;
- работа в сетях с ограничениями на SSH;
- системный VPN поверх TLS.

Это должен быть **собственный туннельный протокол поверх TLS**, если требуется передача произвольного IP-трафика.

Обычный HTTPS reverse proxy не является полноценной заменой IP VPN.

Не обещать пользователю, что TLS-трафик невозможно отличить от обычного HTTPS.

---

# 49. Безопасность TLS-транспорта

Если TLS transport будет реализован:

- TLS 1.3 предпочтительно;
- certificate validation;
- certificate pinning при обоснованной необходимости;
- mutual authentication между приложением и серверным компонентом;
- replay protection;
- session authentication;
- rate limiting;
- защита от unauthorized relay;
- отсутствие хранения пользовательского трафика.

---

# 50. Двойной туннель

Multi-hop должен позволять:

```text
Phone
 ↓
SSH Tunnel #1
 ↓
VPS #1
 ↓
SSH Tunnel #2
 ↓
VPS #2
 ↓
Internet
```

В будущем:

```text
Phone
 ↓
Singapore
 ↓
Japan
 ↓
USA
 ↓
Internet
```

Необходимо учитывать:

- увеличение latency;
- дополнительное шифрование;
- снижение throughput;
- MTU;
- TCP-over-TCP проблемы;
- отказ одного из узлов.

Приложение должно показывать цепочку и состояние каждого узла.

---

# 51. App Store / Google Play требования

До публикации провести отдельный compliance-аудит:

### Apple

- Network Extension entitlement;
- VPN-related App Store requirements;
- privacy manifest;
- required disclosures;
- purchase architecture;
- external payment restrictions;
- региональные правила;
- VPN application review requirements.

### Google Play

- VpnService policy;
- VPN disclosure;
- billing classification;
- privacy requirements;
- foreground service requirements;
- background execution;
- network security requirements.

---

# 52. Privacy Policy

Политика конфиденциальности должна точно описывать:

- какие данные собираются;
- какие данные не собираются;
- какие данные обрабатываются для provisioning;
- какие данные передаются VPS-партнёрам;
- какие данные нужны для лицензирования;
- какие данные используются для диагностики.

Нельзя утверждать отсутствие сбора вообще, если технически собираются telemetry, purchase data или provisioning data.

---

# 53. Support

Основные категории поддержки:

```text
Can't connect
Wrong credentials
Server offline
Server expired
VPN connects but Internet doesn't work
DNS problem
Slow connection
Battery usage
How to buy server
How to use existing VPS
```

Для purchased VPS пользователь не должен самостоятельно общаться с VPS-провайдером по технической настройке.

Наш продукт должен абстрагировать provisioning.

---

# 54. Административная панель

Минимально:

```text
Users
Licenses
Orders
Servers
Providers
Regions
Plans
Provisioning jobs
Errors
Refunds
```

Нельзя отображать или экспортировать пользовательские VPN credentials без крайней необходимости.

---

# 55. Мониторинг

Контролировать:

- provisioning success rate;
- provisioning duration;
- provider API errors;
- VPS creation failure;
- SSH readiness;
- tunnel test success;
- connection failure rate;
- server expiration;
- replacement failure;
- payment failures;
- crash rate.

Отдельно отслеживать показатели по каждому провайдеру.

---

# 56. Резервирование провайдеров

Если Provider A недоступен:

```text
Provider A
   ↓
FAILED
   ↓
Provider B
   ↓
CREATE
```

Пользователь не должен знать о смене backend-провайдера.

Если выбранная страна недоступна:

```text
Singapore temporarily unavailable
```

и предложить доступные альтернативы.

---

# 57. Экономика

Основной доход:

```text
App purchase = $9.99
```

Дополнительный доход:

```text
VPS retail price
-
wholesale infrastructure cost
=
gross VPS margin
```

Целевая reseller margin:

> ориентир 25–40%.

Партнёрская комиссия рассматривается как дополнительный источник дохода, а не как обязательная часть окупаемости приложения.

---

# 58. Принцип ценообразования VPS

Цена для пользователя должна включать:

```text
provider cost
+
payment costs
+
expected refunds
+
support
+
infrastructure backend costs
+
target margin
```

Не продавать VPS ниже полной себестоимости только ради роста количества пользователей.

---

# 59. Refund

Предусмотреть:

- возврат покупки приложения через соответствующую платформу;
- обработку refund webhook;
- отзыв лицензии согласно правилам магазина;
- возврат средств за VPS согласно условиям конкретной инфраструктурной модели.

При удалении приложения лицензия сама по себе не должна автоматически удалять оплаченный пользователем VPS без ясного условия.

---

# 60. Ключевой UX

Финальный пользовательский путь должен выглядеть так:

```text
INSTALL APP
    ↓
TRY FREE
    ↓
┌─────────────────────────┐
│ Do you have a server?   │
│                         │
│ [ YES, ADD SERVER ]     │
│                         │
│ [ NO, BUY SERVER ]      │
└─────────────────────────┘
```

Если `YES`:

```text
IP
Username
Password / Key
    ↓
TEST
    ↓
CONNECTED
```

Если `NO`:

```text
BUY VPN SERVER
    ↓
Choose country
    ↓
Choose duration
    ↓
Purchase
    ↓
Creating server...
    ↓
Configuring...
    ↓
Testing...
    ↓
✓ Server ready
    ↓
[ CONNECT ]
```

Именно этот путь является центральной ценностью продукта.

---

# 61. Главная продуктовая формулировка

Продукт не должен продаваться как:

> SSH client.

Не как:

> VPS manager.

Не как:

> SOCKS proxy.

Не как:

> VPN provider.

Основное позиционирование:

> **Personal VPN using your own server.**

Для пользователя:

> **Купи приложение. Подключи свой сервер или купи готовый VPN-сервер в один клик.**

---

# 62. Критерии готовности MVP

MVP считается готовым, если новый пользователь без специальных технических знаний способен:

1. установить приложение;
2. запустить trial;
3. купить или добавить сервер;
4. дождаться готовности сервера;
5. нажать Connect;
6. получить системный VPN;
7. открыть сайты через VPS;
8. отключиться;
9. повторно подключиться;
10. увидеть срок действия купленного сервера.

При этом пользователь не должен вручную:

- создавать SSH-конфигурацию;
- устанавливать VPN-сервер;
- искать IP;
- копировать пароль из панели хостинга;
- запускать shell-команды;
- устанавливать отдельный VPN-клиент.

---

# 63. Основные технические риски

## Высокий приоритет

1. Реализация полноценного IP-туннеля поверх SSH на iOS.
2. UDP.
3. Network Extension ограничения.
4. App Store review.
5. VPS provisioning API.
6. Безопасное получение credentials.
7. Автоматическая установка серверного компонента.
8. Производительность и battery usage.
9. VPN kill switch.
10. Корректная обработка network transitions.

## Средний приоритет

1. Multi-hop.
2. IPv6.
3. Split tunneling.
4. Несколько провайдеров.
5. Автоматическая замена сервера.

## Низкий приоритет

1. TLS transport.
2. Дополнительные протоколы.
3. Продвинутая аналитика.

---

# 64. Техническая стратегия разработки

Рекомендуемый порядок:

### Этап 1

Сделать proof-of-concept:

```text
iPhone
 ↓
Network Extension
 ↓
SSH
 ↓
Linux VPS
 ↓
Internet
```

Без покупок, backend и красивого UI.

Цель:

> доказать полноценный system-wide IP tunnel.

### Этап 2

Добавить:

- reconnect;
- DNS;
- IPv4/IPv6;
- UDP;
- kill switch;
- performance testing.

### Этап 3

Сделать VPS provisioning adapter.

### Этап 4

Сделать backend.

### Этап 5

Сделать пользовательский UI.

### Этап 6

Интегрировать App Store purchase.

### Этап 7

Google Play.

### Этап 8

Провести store/compliance review.

### Этап 9

Добавить multi-hop.

### Этап 10

Исследовать TLS transport.

---

# 65. Что принципиально не делать

Не превращать приложение в:

- VPN-провайдера;
- хостинг-панель;
- SSH terminal;
- очередной SOCKS client;
- сложный инструмент для Linux-администраторов;
- подписочный VPN;
- приложение с обязательным аккаунтом;
- продукт с собственной сетью серверов.

Ценность должна оставаться простой:

> **Ваш сервер превращается в ваш персональный VPN.**

---

# 66. Финальная архитектура

```text
                         ┌──────────────────────┐
                         │      iOS / Android   │
                         │                      │
                         │       Our App        │
                         │                      │
                         │  My Servers          │
                         │  Buy VPN Server      │
                         │  Connect             │
                         └──────────┬───────────┘
                                    │
                     ┌──────────────┴──────────────┐
                     │                             │
                Control API                  VPN traffic
                     │                             │
                     ▼                             ▼
              ┌─────────────┐              ┌─────────────┐
              │ Our Backend │              │  User VPS   │
              │             │              │             │
              │ Licensing   │              │ SSH         │
              │ Provision   │              │ Tunnel      │
              │ Orders      │              │ Forwarding  │
              │ Providers   │              │             │
              └──────┬──────┘              └──────┬──────┘
                     │                            │
                     ▼                            ▼
             ┌───────────────┐                Internet
             │ VPS Providers │
             │               │
             │ Provider A    │
             │ Provider B    │
             │ Provider C    │
             └───────────────┘
```

Ключевое архитектурное свойство:

```text
User VPN traffic
       ↓
User VPS
       ↓
Internet
```

Наш backend **не находится в этом пути**.

---

# 67. Итог

Продукт строится вокруг трёх простых действий:

```text
CONNECT MY SERVER
```

```text
BUY VPN SERVER
```

```text
CONNECT
```

Пользователь платит **$9.99 один раз за приложение**.

VPS оплачивается **отдельно за выбранный срок**, без обязательной подписки на приложение.

Если пользователь уже имеет VPS, он может использовать его.

Если VPS нет, приложение автоматически создаёт подходящий сервер через инфраструктурного партнёра, получает необходимые параметры, проверяет сервер и добавляет его в список готовых серверов.

Основная техническая задача проекта:

> создать полноценный системный VPN через SSH без необходимости ручной настройки пользователем.

Основная бизнес-задача:

> сделать покупку и использование VPS настолько простыми, чтобы пользователь вообще не воспринимал VPS как отдельный технический продукт.

Основное конкурентное преимущество:

> **от «я хочу свой VPN» до «VPN подключён» без регистрации у хостинга, поиска IP, SSH credentials и ручной настройки.**
