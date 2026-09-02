import Foundation
enum CopyKey {
    // Language selection
    case chooseLanguage, selectLanguageHint
    // Connection
    case connected, connecting, disconnected, connect, disconnect
    // Home
    case ready, yourVPS, addExistingServer, settings
    // Status card
    case protected_, unprotected
    // Add Server & Fields
    case addServer, server, address, username, sshPort
    case passwordOptional, ed25519PrivateKeyOptional, ed25519Hint
    case pinnedHostKey, credentialsHint, addServerTitle, testConnection
    // Placeholders
    case addressPlaceholder, portPlaceholder, usernamePlaceholder
    case passwordPlaceholder, privateKeyPlaceholder, hostKeyPlaceholder
    // UI buttons / alerts
    case cancel, invalidInput, ok
    // Settings
    case languageSection, diagnosticsSection, connectionDiagnostics
    // VPN Settings
    case vpnSettings, protocolTitle, dnsSettings, advanced, protocolDesc, dnsDesc, advancedDesc
    // Locations
    case locations, yourServer, noServerConfigured, addServerLabel, addServerDesc, active
    // About
    case about, version
    // Diagnostics
    case setupProgress, preparingGateway, testingTunnel
    case profile, authentication, passwordKeychain, ed25519Key
    case error, technicalDetails, diagnosticsTitle
    // Server list / Map
    case noServer, setupFailed, selectedServer, ping, status, country, ip
    // Errors
    case sshConnectionFailed, sshHostKeyMismatch, sshAuthFailed, sshTimeout, unknownError
}

struct AppCopy {
    let language: AppLanguage

    func text(_ key: CopyKey) -> String {
        let values: [AppLanguage: [CopyKey: String]] = [
            .english: english, .russian: russian, .spanish: spanish, .german: german,
            .japanese: japanese, .chinese: chinese, .french: french, .italian: italian,
            .portuguese: portuguese, .korean: korean, .arabic: arabic, .hindi: hindi,
            .thai: thai, .turkish: turkish, .polish: polish, .dutch: dutch,
            .vietnamese: vietnamese,
        ]
        return values[language]?[key] ?? english[key]!
    }

    // MARK: - English
    private let english: [CopyKey: String] = [
        .chooseLanguage: "Choose your language", .selectLanguageHint: "Select the language for SSH2VPN",
        .connected: "Connected", .connecting: "Connecting…", .disconnected: "Disconnected", .connect: "Connect",
        .disconnect: "Disconnect", .ready: "Ready", .yourVPS: "Your VPS", .addExistingServer: "Add Existing Server",
        .addServer: "Add Server", .server: "Server", .protected_: "Protected", .unprotected: "Unprotected",
        .address: "IP address or hostname", .username: "Username", .sshPort: "SSH port",
        .testConnection: "Test Connection", .passwordOptional: "Password (optional)",
        .ed25519PrivateKeyOptional: "Ed25519 private key (optional)",
        .ed25519Hint: "Unencrypted OpenSSH Ed25519 or raw 32-byte base64/hex seed. Encrypted keys are rejected explicitly.",
        .pinnedHostKey: "Pinned OpenSSH host key",
        .credentialsHint: "Your password or private key stays on this device and is used only to connect to your VPS.",
        .addServerTitle: "Add Server", .cancel: "Cancel", .invalidInput: "Invalid Input", .ok: "OK",
        .addressPlaceholder: "192.168.1.1 or vpn.example.com", .portPlaceholder: "22", .usernamePlaceholder: "root",
        .passwordPlaceholder: "Password", .privateKeyPlaceholder: "Paste OpenSSH private key...",
        .hostKeyPlaceholder: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5...", .languageSection: "Language",
        .diagnosticsSection: "Diagnostics", .connectionDiagnostics: "Connection diagnostics",
        .vpnSettings: "VPN Settings", .protocolTitle: "Protocol", .dnsSettings: "DNS Settings", .advanced: "Advanced",
        .protocolDesc: "Select VPN protocol", .dnsDesc: "Configure DNS servers", .advancedDesc: "Advanced settings",
        .locations: "Locations", .yourServer: "Your Server", .noServerConfigured: "No server configured",
        .addServerLabel: "Add Server", .addServerDesc: "Connect to your own VPS", .active: "Active", .about: "About",
        .version: "Version", .setupProgress: "Setup progress", .preparingGateway: "Preparing gateway",
        .testingTunnel: "Testing tunnel", .profile: "Profile", .authentication: "Authentication",
        .passwordKeychain: "Password / Keychain", .ed25519Key: "Ed25519 key", .error: "Error",
        .technicalDetails: "Technical details", .diagnosticsTitle: "Diagnostics", .noServer: "No server",
        .setupFailed: "VPN setup failed", .selectedServer: "Selected Server", .ping: "Ping", .status: "Status",
        .country: "Country", .ip: "IP", .settings: "Settings", .sshConnectionFailed: "SSH connection failed",
        .sshHostKeyMismatch: "Host key mismatch", .sshAuthFailed: "Authentication failed",
        .sshTimeout: "Connection timed out", .unknownError: "Unknown error"
    ]

    // MARK: - Russian
    private let russian: [CopyKey: String] = [
        .chooseLanguage: "Выберите язык", .selectLanguageHint: "Выберите язык SSH2VPN", .connected: "Подключено",
        .connecting: "Подключение…", .disconnected: "Отключено", .connect: "Подключить", .disconnect: "Отключить",
        .ready: "Готов", .yourVPS: "Ваш VPS", .addExistingServer: "Добавить свой сервер", .addServer: "Добавить сервер",
        .server: "Сервер", .protected_: "Защищено", .unprotected: "Не защищено", .address: "IP-адрес или имя хоста",
        .username: "Имя пользователя", .sshPort: "SSH-порт", .testConnection: "Проверить подключение",
        .passwordOptional: "Пароль (необязательно)",
        .ed25519PrivateKeyOptional: "Приватный ключ Ed25519 (необязательно)",
        .ed25519Hint: "Незашифрованный OpenSSH Ed25519 или сырой 32-байтный base64/hex seed. Зашифрованные ключи отвергаются.",
        .pinnedHostKey: "Закреплённый ключ хоста OpenSSH",
        .credentialsHint: "Пароль или приватный ключ остаются на этом устройстве и используются только для подключения к VPS.",
        .addServerTitle: "Добавить сервер", .cancel: "Отмена", .invalidInput: "Неверный ввод", .ok: "ОК",
        .addressPlaceholder: "192.168.1.1 или vpn.example.com", .portPlaceholder: "22", .usernamePlaceholder: "root",
        .passwordPlaceholder: "Пароль", .privateKeyPlaceholder: "Вставьте приватный ключ OpenSSH...",
        .hostKeyPlaceholder: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5...", .languageSection: "Язык",
        .diagnosticsSection: "Диагностика", .connectionDiagnostics: "Диагностика подключения",
        .vpnSettings: "Настройки VPN", .protocolTitle: "Протокол", .dnsSettings: "Настройки DNS",
        .advanced: "Дополнительно", .protocolDesc: "Выбрать протокол VPN", .dnsDesc: "Настроить DNS-серверы",
        .advancedDesc: "Дополнительные настройки", .locations: "Локации", .yourServer: "Ваш сервер",
        .noServerConfigured: "Сервер не настроен", .addServerLabel: "Добавить сервер",
        .addServerDesc: "Подключиться к вашему VPS", .active: "Активен", .about: "О приложении", .version: "Версия",
        .setupProgress: "Процесс настройки", .preparingGateway: "Подготовка шлюза", .testingTunnel: "Проверка туннеля",
        .profile: "Профиль", .authentication: "Аутентификация", .passwordKeychain: "Пароль / Связка ключей",
        .ed25519Key: "Ключ Ed25519", .error: "Ошибка", .technicalDetails: "Технические подробности",
        .diagnosticsTitle: "Диагностика", .noServer: "Нет сервера", .setupFailed: "Не удалось настроить VPN",
        .selectedServer: "Выбранный сервер", .ping: "Пинг", .status: "Статус", .country: "Страна", .ip: "IP",
        .settings: "Настройки", .sshConnectionFailed: "Ошибка SSH-подключения",
        .sshHostKeyMismatch: "Несовпадение ключа хоста", .sshAuthFailed: "Ошибка аутентификации",
        .sshTimeout: "Время подключения истекло", .unknownError: "Неизвестная ошибка"
    ]

    // MARK: - Spanish
    private let spanish: [CopyKey: String] = [
        .chooseLanguage: "Elige tu idioma", .selectLanguageHint: "Selecciona el idioma de SSH2VPN",
        .connected: "Conectado", .connecting: "Conectando…", .disconnected: "Desconectado", .connect: "Conectar",
        .disconnect: "Desconectar", .ready: "Listo", .yourVPS: "Tu VPS", .addExistingServer: "Añadir servidor existente",
        .addServer: "Añadir servidor", .server: "Servidor", .protected_: "Protegido", .unprotected: "No protegido",
        .address: "IP o nombre de host", .username: "Usuario", .sshPort: "Puerto SSH",
        .testConnection: "Probar conexión", .passwordOptional: "Contraseña (opcional)",
        .ed25519PrivateKeyOptional: "Clave privada Ed25519 (opcional)",
        .ed25519Hint: "OpenSSH Ed25519 sin cifrar o semilla raw de 32 bytes en base64/hex. Las claves cifradas se rechazan.",
        .pinnedHostKey: "Clave de host OpenSSH fijada",
        .credentialsHint: "Tus credenciales se usan solo para conectar con tu VPS.", .addServerTitle: "Añadir servidor",
        .cancel: "Cancelar", .invalidInput: "Entrada no válida", .ok: "OK",
        .addressPlaceholder: "192.168.1.1 o vpn.ejemplo.com", .portPlaceholder: "22", .usernamePlaceholder: "root",
        .passwordPlaceholder: "Contraseña", .privateKeyPlaceholder: "Pega tu clave privada OpenSSH...",
        .hostKeyPlaceholder: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5...", .languageSection: "Idioma",
        .diagnosticsSection: "Diagnósticos", .connectionDiagnostics: "Diagnóstico de conexión",
        .vpnSettings: "Ajustes de VPN", .protocolTitle: "Protocolo", .dnsSettings: "Ajustes de DNS",
        .advanced: "Avanzado", .protocolDesc: "Seleccionar protocolo VPN", .dnsDesc: "Configurar servidores DNS",
        .advancedDesc: "Ajustes avanzados", .locations: "Ubicaciones", .yourServer: "Tu servidor",
        .noServerConfigured: "Ningún servidor configurado", .addServerLabel: "Añadir servidor",
        .addServerDesc: "Conectar a tu propio VPS", .active: "Activo", .about: "Acerca de", .version: "Versión",
        .setupProgress: "Progreso de configuración", .preparingGateway: "Preparando pasarela",
        .testingTunnel: "Probando túnel", .profile: "Perfil", .authentication: "Autenticación",
        .passwordKeychain: "Contraseña / Llavero", .ed25519Key: "Clave Ed25519", .error: "Error",
        .technicalDetails: "Detalles técnicos", .diagnosticsTitle: "Diagnósticos", .noServer: "Sin servidor",
        .setupFailed: "No se pudo configurar la VPN", .selectedServer: "Servidor seleccionado", .ping: "Ping",
        .status: "Estado", .country: "País", .ip: "IP", .settings: "Ajustes",
        .sshConnectionFailed: "Error de conexión SSH", .sshHostKeyMismatch: "Clave de host no coincide",
        .sshAuthFailed: "Error de autenticación", .sshTimeout: "Tiempo de conexión agotado",
        .unknownError: "Error desconocido"
    ]

    // MARK: - German
    private let german: [CopyKey: String] = [
        .chooseLanguage: "Sprache wählen", .selectLanguageHint: "Sprache für SSH2VPN auswählen", .connected: "Verbunden",
        .connecting: "Verbinde…", .disconnected: "Getrennt", .connect: "Verbinden", .disconnect: "Trennen",
        .ready: "Bereit", .yourVPS: "Dein VPS", .addExistingServer: "Vorhandenen Server hinzufügen",
        .addServer: "Server hinzufügen", .server: "Server", .protected_: "Geschützt", .unprotected: "Ungeschützt",
        .address: "IP-Adresse oder Hostname", .username: "Benutzername", .sshPort: "SSH-Port",
        .testConnection: "Verbindung testen", .passwordOptional: "Passwort (optional)",
        .ed25519PrivateKeyOptional: "Ed25519 privater Schlüssel (optional)",
        .ed25519Hint: "Unverschlüsselter OpenSSH Ed25519 oder roher 32-Byte base64/hex Seed. Verschlüsselte Schlüssel werden abgelehnt.",
        .pinnedHostKey: "Fixierter OpenSSH Host-Key",
        .credentialsHint: "Deine Zugangsdaten werden nur für die Verbindung mit deinem VPS verwendet.",
        .addServerTitle: "Server hinzufügen", .cancel: "Abbrechen", .invalidInput: "Ungültige Eingabe", .ok: "OK",
        .addressPlaceholder: "192.168.1.1 oder vpn.beispiel.de", .portPlaceholder: "22", .usernamePlaceholder: "root",
        .passwordPlaceholder: "Passwort", .privateKeyPlaceholder: "OpenSSH-Privatschlüssel einfügen...",
        .hostKeyPlaceholder: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5...", .languageSection: "Sprache",
        .diagnosticsSection: "Diagnose", .connectionDiagnostics: "Verbindungsdiagnose",
        .vpnSettings: "VPN-Einstellungen", .protocolTitle: "Protokoll", .dnsSettings: "DNS-Einstellungen",
        .advanced: "Erweitert", .protocolDesc: "VPN-Protokoll auswählen", .dnsDesc: "DNS-Server konfigurieren",
        .advancedDesc: "Erweiterte Einstellungen", .locations: "Standorte", .yourServer: "Dein Server",
        .noServerConfigured: "Kein Server konfiguriert", .addServerLabel: "Server hinzufügen",
        .addServerDesc: "Mit eigenem VPS verbinden", .active: "Aktiv", .about: "Über", .version: "Version",
        .setupProgress: "Einrichtungsfortschritt", .preparingGateway: "Gateway wird vorbereitet",
        .testingTunnel: "Tunnel wird getestet", .profile: "Profil", .authentication: "Authentifizierung",
        .passwordKeychain: "Passwort / Schlüsselbund", .ed25519Key: "Ed25519-Schlüssel", .error: "Fehler",
        .technicalDetails: "Technische Details", .diagnosticsTitle: "Diagnose", .noServer: "Kein Server",
        .setupFailed: "VPN konnte nicht eingerichtet werden", .selectedServer: "Ausgewählter Server", .ping: "Ping",
        .status: "Status", .country: "Land", .ip: "IP", .settings: "Einstellungen",
        .sshConnectionFailed: "SSH-Verbindung fehlgeschlagen", .sshHostKeyMismatch: "Host-Key passt nicht",
        .sshAuthFailed: "Authentifizierung fehlgeschlagen", .sshTimeout: "Verbindung Zeitüberschreitung",
        .unknownError: "Unbekannter Fehler"
    ]

    // MARK: - Japanese
    private let japanese: [CopyKey: String] = [
        .chooseLanguage: "言語を選択", .selectLanguageHint: "SSH2VPNの言語を選択してください", .connected: "接続済み", .connecting: "接続中…",
        .disconnected: "未接続", .connect: "接続", .disconnect: "切断", .ready: "準備完了", .yourVPS: "あなたのVPS",
        .addExistingServer: "既存のサーバーを追加", .addServer: "サーバーを追加", .server: "サーバー", .protected_: "保護されています",
        .unprotected: "保護されていません", .address: "IPアドレスまたはホスト名", .username: "ユーザー名", .sshPort: "SSHポート",
        .testConnection: "接続を確認", .passwordOptional: "パスワード（任意）", .ed25519PrivateKeyOptional: "Ed25519秘密鍵（任意）",
        .ed25519Hint: "暗号化されていないOpenSSH Ed25519または生の32バイトbase64/hexシード。暗号化された鍵は明示的に拒否されます。",
        .pinnedHostKey: "固定OpenSSHホストキー", .credentialsHint: "認証情報はVPSへの接続にのみ使用され、この端末に保管されます。",
        .addServerTitle: "サーバーを追加", .cancel: "キャンセル", .invalidInput: "無効な入力", .ok: "OK",
        .addressPlaceholder: "192.168.1.1 または vpn.example.com", .portPlaceholder: "22", .usernamePlaceholder: "root",
        .passwordPlaceholder: "パスワード", .privateKeyPlaceholder: "OpenSSH秘密鍵を貼り付け...",
        .hostKeyPlaceholder: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5...", .languageSection: "言語", .diagnosticsSection: "診断",
        .connectionDiagnostics: "接続診断", .vpnSettings: "VPN設定", .protocolTitle: "プロトコル", .dnsSettings: "DNS設定",
        .advanced: "詳細設定", .protocolDesc: "VPNプロトコルを選択", .dnsDesc: "DNSサーバーを設定", .advancedDesc: "高度な設定",
        .locations: "ロケーション", .yourServer: "マイサーバー", .noServerConfigured: "サーバーが設定されていません", .addServerLabel: "サーバーを追加",
        .addServerDesc: "自身のVPSに接続", .active: "アクティブ", .about: "アプリについて", .version: "バージョン",
        .setupProgress: "セットアップの進行状況", .preparingGateway: "ゲートウェイの準備", .testingTunnel: "トンネルのテスト", .profile: "プロフィール",
        .authentication: "認証", .passwordKeychain: "パスワード / キーチェーン", .ed25519Key: "Ed25519鍵", .error: "エラー",
        .technicalDetails: "技術的な詳細", .diagnosticsTitle: "診断", .noServer: "サーバーなし", .setupFailed: "VPNの設定に失敗しました",
        .selectedServer: "選択されたサーバー", .ping: "Ping", .status: "ステータス", .country: "国", .ip: "IP", .settings: "設定",
        .sshConnectionFailed: "SSH接続に失敗", .sshHostKeyMismatch: "ホストキーが一致しません", .sshAuthFailed: "認証に失敗",
        .sshTimeout: "接続がタイムアウトしました", .unknownError: "不明なエラー"
    ]

    // MARK: - Chinese (Simplified)
    private let chinese: [CopyKey: String] = [
        .chooseLanguage: "选择语言", .selectLanguageHint: "选择 SSH2VPN 的语言", .connected: "已连接", .connecting: "连接中…",
        .disconnected: "未连接", .connect: "连接", .disconnect: "断开", .ready: "就绪", .yourVPS: "你的 VPS",
        .addExistingServer: "添加现有服务器", .addServer: "添加服务器", .server: "服务器", .protected_: "已受保护", .unprotected: "未受保护",
        .address: "IP 地址或主机名", .username: "用户名", .sshPort: "SSH 端口", .testConnection: "测试连接",
        .passwordOptional: "密码（可选）", .ed25519PrivateKeyOptional: "Ed25519 私钥（可选）",
        .ed25519Hint: "未加密的 OpenSSH Ed25519 或原始 32 字节 base64/hex 种子。加密的密钥将被明确拒绝。", .pinnedHostKey: "固定的 OpenSSH 主机密钥",
        .credentialsHint: "凭据仅用于连接你的 VPS，并保存在此设备上。", .addServerTitle: "添加服务器", .cancel: "取消", .invalidInput: "输入无效",
        .ok: "确定", .addressPlaceholder: "192.168.1.1 或 vpn.example.com", .portPlaceholder: "22",
        .usernamePlaceholder: "root", .passwordPlaceholder: "密码", .privateKeyPlaceholder: "粘贴 OpenSSH 私钥...",
        .hostKeyPlaceholder: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5...", .languageSection: "语言", .diagnosticsSection: "诊断",
        .connectionDiagnostics: "连接诊断", .vpnSettings: "VPN 设置", .protocolTitle: "协议", .dnsSettings: "DNS 设置",
        .advanced: "高级", .protocolDesc: "选择 VPN 协议", .dnsDesc: "配置 DNS 服务器", .advancedDesc: "高级设置", .locations: "节点位置",
        .yourServer: "你的服务器", .noServerConfigured: "未配置服务器", .addServerLabel: "添加服务器", .addServerDesc: "连接到你的 VPS",
        .active: "已启用", .about: "关于", .version: "版本", .setupProgress: "设置进度", .preparingGateway: "准备网关",
        .testingTunnel: "测试隧道", .profile: "配置文件", .authentication: "认证", .passwordKeychain: "密码 / 钥匙串",
        .ed25519Key: "Ed25519 密钥", .error: "错误", .technicalDetails: "技术详情", .diagnosticsTitle: "诊断", .noServer: "没有服务器",
        .setupFailed: "VPN 设置失败", .selectedServer: "选定的服务器", .ping: "Ping", .status: "状态", .country: "国家", .ip: "IP",
        .settings: "设置", .sshConnectionFailed: "SSH 连接失败", .sshHostKeyMismatch: "主机密钥不匹配", .sshAuthFailed: "认证失败",
        .sshTimeout: "连接超时", .unknownError: "未知错误"
    ]

    // MARK: - French
    private let french: [CopyKey: String] = [
        .chooseLanguage: "Choisissez votre langue", .selectLanguageHint: "Sélectionnez la langue de SSH2VPN",
        .connected: "Connecté", .connecting: "Connexion…", .disconnected: "Déconnecté", .connect: "Connecter",
        .disconnect: "Déconnecter", .ready: "Prêt", .yourVPS: "Votre VPS",
        .addExistingServer: "Ajouter un serveur existant", .addServer: "Ajouter un serveur", .server: "Serveur",
        .protected_: "Protégé", .unprotected: "Non protégé", .address: "Adresse IP ou nom d'hôte",
        .username: "Nom d'utilisateur", .sshPort: "Port SSH", .testConnection: "Tester la connexion",
        .passwordOptional: "Mot de passe (facultatif)", .ed25519PrivateKeyOptional: "Clé privée Ed25519 (facultatif)",
        .ed25519Hint: "OpenSSH Ed25519 non chiffré ou graine raw 32 octets base64/hex. Les clés chiffrées sont rejetées.",
        .pinnedHostKey: "Clé d'hôte OpenSSH épinglée",
        .credentialsHint: "Vos identifiants sont utilisés uniquement pour vous connecter à votre VPS.",
        .addServerTitle: "Ajouter un serveur", .cancel: "Annuler", .invalidInput: "Saisie invalide", .ok: "OK",
        .addressPlaceholder: "192.168.1.1 ou vpn.exemple.com", .portPlaceholder: "22", .usernamePlaceholder: "root",
        .passwordPlaceholder: "Mot de passe", .privateKeyPlaceholder: "Collez la clé privée OpenSSH...",
        .hostKeyPlaceholder: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5...", .languageSection: "Langue",
        .diagnosticsSection: "Diagnostics", .connectionDiagnostics: "Diagnostic de connexion",
        .vpnSettings: "Paramètres VPN", .protocolTitle: "Protocole", .dnsSettings: "Paramètres DNS", .advanced: "Avancé",
        .protocolDesc: "Sélectionner le protocole VPN", .dnsDesc: "Configurer les serveurs DNS",
        .advancedDesc: "Paramètres avancés", .locations: "Emplacements", .yourServer: "Votre serveur",
        .noServerConfigured: "Aucun serveur configuré", .addServerLabel: "Ajouter un serveur",
        .addServerDesc: "Se connecter à votre VPS", .active: "Actif", .about: "À propos", .version: "Version",
        .setupProgress: "Progression de la configuration", .preparingGateway: "Préparation de la passerelle",
        .testingTunnel: "Test du tunnel", .profile: "Profil", .authentication: "Authentification",
        .passwordKeychain: "Mot de passe / Trousseau", .ed25519Key: "Clé Ed25519", .error: "Erreur",
        .technicalDetails: "Détails techniques", .diagnosticsTitle: "Diagnostics", .noServer: "Aucun serveur",
        .setupFailed: "Échec de la configuration VPN", .selectedServer: "Serveur sélectionné", .ping: "Ping",
        .status: "Statut", .country: "Pays", .ip: "IP", .settings: "Paramètres",
        .sshConnectionFailed: "Échec de la connexion SSH", .sshHostKeyMismatch: "Clé d'hôte ne correspond pas",
        .sshAuthFailed: "Échec de l'authentification", .sshTimeout: "Délai de connexion dépassé",
        .unknownError: "Erreur inconnue"
    ]

    // MARK: - Italian
    private let italian: [CopyKey: String] = [
        .chooseLanguage: "Scegli la tua lingua", .selectLanguageHint: "Seleziona la lingua di SSH2VPN",
        .connected: "Connesso", .connecting: "Connessione…", .disconnected: "Disconnesso", .connect: "Connetti",
        .disconnect: "Disconnetti", .ready: "Pronto", .yourVPS: "Il tuo VPS",
        .addExistingServer: "Aggiungi server esistente", .addServer: "Aggiungi server", .server: "Server",
        .protected_: "Protetto", .unprotected: "Non protetto", .address: "Indirizzo IP o nome host",
        .username: "Nome utente", .sshPort: "Porta SSH", .testConnection: "Testa connessione",
        .passwordOptional: "Password (opzionale)", .ed25519PrivateKeyOptional: "Chiave privata Ed25519 (opzionale)",
        .ed25519Hint: "OpenSSH Ed25519 non crittografato o seed raw 32 byte base64/hex. Le chiavi crittografate sono rifiutate.",
        .pinnedHostKey: "Chiave host OpenSSH fissata",
        .credentialsHint: "Le tue credenziali vengono usate solo per connetterti al tuo VPS.",
        .addServerTitle: "Aggiungi server", .cancel: "Annulla", .invalidInput: "Input non valido", .ok: "OK",
        .addressPlaceholder: "192.168.1.1 o vpn.esempio.it", .portPlaceholder: "22", .usernamePlaceholder: "root",
        .passwordPlaceholder: "Password", .privateKeyPlaceholder: "Incolla chiave privata OpenSSH...",
        .hostKeyPlaceholder: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5...", .languageSection: "Lingua",
        .diagnosticsSection: "Diagnostica", .connectionDiagnostics: "Diagnostica connessione",
        .vpnSettings: "Impostazioni VPN", .protocolTitle: "Protocollo", .dnsSettings: "Impostazioni DNS",
        .advanced: "Avanzate", .protocolDesc: "Seleziona protocollo VPN", .dnsDesc: "Configura server DNS",
        .advancedDesc: "Impostazioni avanzate", .locations: "Posizioni", .yourServer: "Il tuo server",
        .noServerConfigured: "Nessun server configurato", .addServerLabel: "Aggiungi server",
        .addServerDesc: "Connettiti al tuo VPS", .active: "Attivo", .about: "Info", .version: "Versione",
        .setupProgress: "Avanzamento configurazione", .preparingGateway: "Preparazione gateway",
        .testingTunnel: "Test tunnel", .profile: "Profilo", .authentication: "Autenticazione",
        .passwordKeychain: "Password / Portachiavi", .ed25519Key: "Chiave Ed25519", .error: "Errore",
        .technicalDetails: "Dettagli tecnici", .diagnosticsTitle: "Diagnostica", .noServer: "Nessun server",
        .setupFailed: "Configurazione VPN fallita", .selectedServer: "Server selezionato", .ping: "Ping",
        .status: "Stato", .country: "Paese", .ip: "IP", .settings: "Impostazioni",
        .sshConnectionFailed: "Connessione SSH fallita", .sshHostKeyMismatch: "Chiave host non corrisponde",
        .sshAuthFailed: "Autenticazione fallita", .sshTimeout: "Connessione scaduta",
        .unknownError: "Errore sconosciuto"
    ]

    // MARK: - Portuguese (Brazil)
    private let portuguese: [CopyKey: String] = [
        .chooseLanguage: "Escolha seu idioma", .selectLanguageHint: "Selecione o idioma do SSH2VPN",
        .connected: "Conectado", .connecting: "Conectando…", .disconnected: "Desconectado", .connect: "Conectar",
        .disconnect: "Desconectar", .ready: "Pronto", .yourVPS: "Seu VPS",
        .addExistingServer: "Adicionar servidor existente", .addServer: "Adicionar servidor", .server: "Servidor",
        .protected_: "Protegido", .unprotected: "Desprotegido", .address: "Endereço IP ou nome de host",
        .username: "Nome de usuário", .sshPort: "Porta SSH", .testConnection: "Testar conexão",
        .passwordOptional: "Senha (opcional)", .ed25519PrivateKeyOptional: "Chave privada Ed25519 (opcional)",
        .ed25519Hint: "OpenSSH Ed25519 não criptografado ou semente raw de 32 bytes base64/hex. Chaves criptografadas são rejeitadas.",
        .pinnedHostKey: "Chave de host OpenSSH fixada",
        .credentialsHint: "Suas credenciais são usadas apenas para se conectar ao seu VPS.",
        .addServerTitle: "Adicionar servidor", .cancel: "Cancelar", .invalidInput: "Entrada inválida", .ok: "OK",
        .addressPlaceholder: "192.168.1.1 ou vpn.exemplo.com", .portPlaceholder: "22", .usernamePlaceholder: "root",
        .passwordPlaceholder: "Senha", .privateKeyPlaceholder: "Cole sua chave privada OpenSSH...",
        .hostKeyPlaceholder: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5...", .languageSection: "Idioma",
        .diagnosticsSection: "Diagnósticos", .connectionDiagnostics: "Diagnóstico de conexão",
        .vpnSettings: "Configurações de VPN", .protocolTitle: "Protocolo", .dnsSettings: "Configurações de DNS",
        .advanced: "Avançado", .protocolDesc: "Selecionar protocolo VPN", .dnsDesc: "Configurar servidores DNS",
        .advancedDesc: "Configurações avançadas", .locations: "Locais", .yourServer: "Seu servidor",
        .noServerConfigured: "Nenhum servidor configurado", .addServerLabel: "Adicionar servidor",
        .addServerDesc: "Conectar ao seu próprio VPS", .active: "Ativo", .about: "Sobre", .version: "Versão",
        .setupProgress: "Progresso da configuração", .preparingGateway: "Preparando gateway",
        .testingTunnel: "Testando túnel", .profile: "Perfil", .authentication: "Autenticação",
        .passwordKeychain: "Senha / Chaveiro", .ed25519Key: "Chave Ed25519", .error: "Erro",
        .technicalDetails: "Detalhes técnicos", .diagnosticsTitle: "Diagnósticos", .noServer: "Sem servidor",
        .setupFailed: "Falha na configuração da VPN", .selectedServer: "Servidor selecionado", .ping: "Ping",
        .status: "Status", .country: "País", .ip: "IP", .settings: "Configurações",
        .sshConnectionFailed: "Falha na conexão SSH", .sshHostKeyMismatch: "Chave de host não corresponde",
        .sshAuthFailed: "Falha na autenticação", .sshTimeout: "Tempo de conexão esgotado",
        .unknownError: "Erro desconhecido"
    ]

    // MARK: - Korean
    private let korean: [CopyKey: String] = [
        .chooseLanguage: "언어 선택", .selectLanguageHint: "SSH2VPN 언어를 선택하세요", .connected: "연결됨", .connecting: "연결 중…",
        .disconnected: "연결 끊김", .connect: "연결", .disconnect: "연결 해제", .ready: "준비", .yourVPS: "내 VPS",
        .addExistingServer: "기존 서버 추가", .addServer: "서버 추가", .server: "서버", .protected_: "보호됨", .unprotected: "보호되지 않음",
        .address: "IP 주소 또는 호스트명", .username: "사용자 이름", .sshPort: "SSH 포트", .testConnection: "연결 테스트",
        .passwordOptional: "비밀번호 (선택)", .ed25519PrivateKeyOptional: "Ed25519 개인 키 (선택)",
        .ed25519Hint: "암호화되지 않은 OpenSSH Ed25519 또는 원시 32바이트 base64/hex 시드. 암호화된 키는 명시적으로 거부됩니다.",
        .pinnedHostKey: "고정된 OpenSSH 호스트 키", .credentialsHint: "자격 증명은 VPS에 연결하는 데만 사용되며 이 장치에 저장됩니다.",
        .addServerTitle: "서버 추가", .cancel: "취소", .invalidInput: "잘못된 입력", .ok: "확인",
        .addressPlaceholder: "192.168.1.1 또는 vpn.example.com", .portPlaceholder: "22", .usernamePlaceholder: "root",
        .passwordPlaceholder: "비밀번호", .privateKeyPlaceholder: "OpenSSH 개인 키 붙여넣기...",
        .hostKeyPlaceholder: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5...", .languageSection: "언어", .diagnosticsSection: "진단",
        .connectionDiagnostics: "연결 진단", .vpnSettings: "VPN 설정", .protocolTitle: "프로토콜", .dnsSettings: "DNS 설정",
        .advanced: "고급 설정", .protocolDesc: "VPN 프로토콜 선택", .dnsDesc: "DNS 서버 설정", .advancedDesc: "고급 옵션",
        .locations: "서버 위치", .yourServer: "내 서버", .noServerConfigured: "구성된 서버 없음", .addServerLabel: "서버 추가",
        .addServerDesc: "내 VPS에 연결", .active: "활성", .about: "정보", .version: "버전", .setupProgress: "설정 진행 상황",
        .preparingGateway: "게이트웨이 준비 중", .testingTunnel: "터널 테스트 중", .profile: "프로필", .authentication: "인증",
        .passwordKeychain: "비밀번호 / 키체인", .ed25519Key: "Ed25519 키", .error: "오류", .technicalDetails: "기술적 세부사항",
        .diagnosticsTitle: "진단", .noServer: "서버 없음", .setupFailed: "VPN 설정 실패", .selectedServer: "선택된 서버", .ping: "Ping",
        .status: "상태", .country: "국가", .ip: "IP", .settings: "설정", .sshConnectionFailed: "SSH 연결 실패",
        .sshHostKeyMismatch: "호스트 키 불일치", .sshAuthFailed: "인증 실패", .sshTimeout: "연결 시간 초과", .unknownError: "알 수 없는 오류"
    ]

    // MARK: - Arabic
    private let arabic: [CopyKey: String] = [
        .chooseLanguage: "اختر لغتك", .selectLanguageHint: "اختر لغة SSH2VPN", .connected: "متصل",
        .connecting: "جاري الاتصال…", .disconnected: "غير متصل", .connect: "اتصل", .disconnect: "قطع الاتصال",
        .ready: "جاهز", .yourVPS: "خادمك VPS", .addExistingServer: "إضافة خادم موجود", .addServer: "إضافة خادم",
        .server: "خادم", .protected_: "محمي", .unprotected: "غير محمي", .address: "عنوان IP أو اسم المضيف",
        .username: "اسم المستخدم", .sshPort: "منفذ SSH", .testConnection: "اختبار الاتصال",
        .passwordOptional: "كلمة المرور (اختياري)", .ed25519PrivateKeyOptional: "مفتاح خاص Ed25519 (اختياري)",
        .ed25519Hint: "OpenSSH Ed25519 غير مشفر أو بذرة raw 32 بايت base64/hex. المفاتيح المشفرة تُرفض صراحةً.",
        .pinnedHostKey: "مفتاح المضيف OpenSSH المثبت",
        .credentialsHint: "تُستخدم بيانات الاعتماد فقط للاتصال بخادم VPS الخاص بك.", .addServerTitle: "إضافة خادم",
        .cancel: "إلغاء", .invalidInput: "إدخال غير صالح", .ok: "موافق",
        .addressPlaceholder: "192.168.1.1 أو vpn.example.com", .portPlaceholder: "22", .usernamePlaceholder: "root",
        .passwordPlaceholder: "كلمة المرور", .privateKeyPlaceholder: "الصق مفتاح OpenSSH الخاص...",
        .hostKeyPlaceholder: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5...", .languageSection: "اللغة",
        .diagnosticsSection: "التشخيص", .connectionDiagnostics: "تشخيص الاتصال", .vpnSettings: "إعدادات VPN",
        .protocolTitle: "البروتوكول", .dnsSettings: "إعدادات DNS", .advanced: "متقدم",
        .protocolDesc: "اختر بروتوكول VPN", .dnsDesc: "تكوين خوادم DNS", .advancedDesc: "إعدادات متقدمة",
        .locations: "المواقع", .yourServer: "خادمك", .noServerConfigured: "لا يوجد خادم مهيأ",
        .addServerLabel: "إضافة خادم", .addServerDesc: "الاتصال بخادم VPS الخاص بك", .active: "نشط",
        .about: "حول التطبيق", .version: "الإصدار", .setupProgress: "تقدم الإعداد", .preparingGateway: "إعداد بوابة",
        .testingTunnel: "اختبار النفق", .profile: "الملف الشخصي", .authentication: "المصادقة",
        .passwordKeychain: "كلمة المرور / سلسلة المفاتيح", .ed25519Key: "مفتاح Ed25519", .error: "خطأ",
        .technicalDetails: "تفاصيل تقنية", .diagnosticsTitle: "التشخيص", .noServer: "لا يوجد خادم",
        .setupFailed: "فشل إعداد VPN", .selectedServer: "الخادم المحدد", .ping: "Ping", .status: "الحالة",
        .country: "البلد", .ip: "IP", .settings: "الإعدادات", .sshConnectionFailed: "فشل اتصال SSH",
        .sshHostKeyMismatch: "مفتاح المضيف لا يتطابق", .sshAuthFailed: "فشلت المصادقة",
        .sshTimeout: "انتهت مهلة الاتصال", .unknownError: "خطأ غير معروف"
    ]

    // MARK: - Hindi
    private let hindi: [CopyKey: String] = [
        .chooseLanguage: "अपनी भाषा चुनें", .selectLanguageHint: "SSH2VPN की भाषा चुनें", .connected: "कनेक्टेड",
        .connecting: "कनेक्ट हो रहा है…", .disconnected: "डिस्कनेक्टेड", .connect: "कनेक्ट करें",
        .disconnect: "डिस्कनेक्ट करें", .ready: "तैयार", .yourVPS: "आपका VPS", .addExistingServer: "मौजूदा सर्वर जोड़ें",
        .addServer: "सर्वर जोड़ें", .server: "सर्वर", .protected_: "सुरक्षित", .unprotected: "असुरक्षित",
        .address: "IP पता या होस्टनाम", .username: "उपयोगकर्ता नाम", .sshPort: "SSH पोर्ट",
        .testConnection: "कनेक्शन का परीक्षण करें", .passwordOptional: "पासवर्ड (वैकल्पिक)",
        .ed25519PrivateKeyOptional: "Ed25519 प्राइवेट की (वैकल्पिक)",
        .ed25519Hint: "गैर-एन्क्रिप्टेड OpenSSH Ed25519 या कच्ची 32-बाइट base64/hex seed। एन्क्रिप्टेड की स्पष्ट रूप से अस्वीकार की जाती हैं।",
        .pinnedHostKey: "पिन की गई OpenSSH होस्ट की",
        .credentialsHint: "आपका पासवर्ड या प्राइवेट की केवल आपके VPS से कनेक्ट करने के लिए उपयोग होता है।",
        .addServerTitle: "सर्वर जोड़ें", .cancel: "रद्द करें", .invalidInput: "अमान्य इनपुट", .ok: "ठीक",
        .addressPlaceholder: "192.168.1.1 या vpn.example.com", .portPlaceholder: "22", .usernamePlaceholder: "root",
        .passwordPlaceholder: "पासवर्ड", .privateKeyPlaceholder: "OpenSSH प्राइवेट की चिपकाएँ...",
        .hostKeyPlaceholder: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5...", .languageSection: "भाषा",
        .diagnosticsSection: "डायग्नोस्टिक्स", .connectionDiagnostics: "कनेक्शन डायग्नोस्टिक्स",
        .vpnSettings: "VPN सेटिंग्स", .protocolTitle: "प्रोटोकॉल", .dnsSettings: "DNS सेटिंग्स", .advanced: "उन्नत",
        .protocolDesc: "VPN प्रोटोकॉल चुनें", .dnsDesc: "DNS सर्वर कॉन्फ़िगर करें", .advancedDesc: "उन्नत सेटिंग्स",
        .locations: "स्थान", .yourServer: "आपका सर्वर", .noServerConfigured: "कोई सर्वर कॉन्फ़िगर नहीं है",
        .addServerLabel: "सर्वर जोड़ें", .addServerDesc: "अपने VPS से कनेक्ट करें", .active: "सक्रिय",
        .about: "के बारे में", .version: "संस्करण", .setupProgress: "सेटअप प्रगति",
        .preparingGateway: "गेटवे तैयार कर रहा है", .testingTunnel: "टनल का परीक्षण", .profile: "प्रोफ़ाइल",
        .authentication: "प्रमाणीकरण", .passwordKeychain: "पासवर्ड / कीचेन", .ed25519Key: "Ed25519 की", .error: "त्रुटि",
        .technicalDetails: "तकनीकी विवरण", .diagnosticsTitle: "डायग्नोस्टिक्स", .noServer: "कोई सर्वर नहीं",
        .setupFailed: "VPN सेटअप विफल", .selectedServer: "चयनित सर्वर", .ping: "Ping", .status: "स्थिति",
        .country: "देश", .ip: "IP", .settings: "सेटिंग्स", .sshConnectionFailed: "SSH कनेक्शन विफल",
        .sshHostKeyMismatch: "होस्ट की मेल नहीं खाता", .sshAuthFailed: "प्रमाणीकरण विफल",
        .sshTimeout: "कनेक्शन का समय समाप्त", .unknownError: "अज्ञात त्रुटि"
    ]

    // MARK: - Thai
    private let thai: [CopyKey: String] = [
        .chooseLanguage: "เลือกภาษาของคุณ", .selectLanguageHint: "เลือกภาษาของ SSH2VPN", .connected: "เชื่อมต่อแล้ว",
        .connecting: "กำลังเชื่อมต่อ…", .disconnected: "ไม่ได้เชื่อมต่อ", .connect: "เชื่อมต่อ",
        .disconnect: "ตัดการเชื่อมต่อ", .ready: "พร้อม", .yourVPS: "VPS ของคุณ",
        .addExistingServer: "เพิ่มเซิร์ฟเวอร์ที่มีอยู่", .addServer: "เพิ่มเซิร์ฟเวอร์", .server: "เซิร์ฟเวอร์",
        .protected_: "ปลอดภัย", .unprotected: "ไม่ปลอดภัย", .address: "IP หรือชื่อโฮสต์", .username: "ชื่อผู้ใช้",
        .sshPort: "พอร์ต SSH", .testConnection: "ทดสอบการเชื่อมต่อ", .passwordOptional: "รหัสผ่าน (ไม่บังคับ)",
        .ed25519PrivateKeyOptional: "คีย์ส่วนตัว Ed25519 (ไม่บังคับ)",
        .ed25519Hint: "OpenSSH Ed25519 ที่ไม่ได้เข้ารหัส หรือเมล็ด raw 32 ไบต์ base64/hex คีย์ที่เข้ารหัสจะถูกปฏิเสธอย่างชัดเจน",
        .pinnedHostKey: "คีย์โฮสต์ OpenSSH ที่ปักหมุด",
        .credentialsHint: "ข้อมูลรับรองใช้เฉพาะสำหรับเชื่อมต่อกับ VPS ของคุณเท่านั้น",
        .addServerTitle: "เพิ่มเซิร์ฟเวอร์", .cancel: "ยกเลิก", .invalidInput: "ข้อมูลไม่ถูกต้อง", .ok: "ตกลง",
        .addressPlaceholder: "192.168.1.1 หรือ vpn.example.com", .portPlaceholder: "22", .usernamePlaceholder: "root",
        .passwordPlaceholder: "รหัสผ่าน", .privateKeyPlaceholder: "วางคีย์ส่วนตัว OpenSSH...",
        .hostKeyPlaceholder: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5...", .languageSection: "ภาษา",
        .diagnosticsSection: "การวินิจฉัย", .connectionDiagnostics: "การวินิจฉัยการเชื่อมต่อ",
        .vpnSettings: "การตั้งค่า VPN", .protocolTitle: "โปรโตคอล", .dnsSettings: "การตั้งค่า DNS", .advanced: "ขั้นสูง",
        .protocolDesc: "เลือกโปรโตคอล VPN", .dnsDesc: "กำหนดค่าเซิร์ฟเวอร์ DNS", .advancedDesc: "การตั้งค่าขั้นสูง",
        .locations: "ตำแหน่ง", .yourServer: "เซิร์ฟเวอร์ของคุณ", .noServerConfigured: "ยังไม่ได้ตั้งค่าเซิร์ฟเวอร์",
        .addServerLabel: "เพิ่มเซิร์ฟเวอร์", .addServerDesc: "เชื่อมต่อกับ VPS ของคุณ", .active: "ใช้งานอยู่",
        .about: "เกี่ยวกับ", .version: "เวอร์ชัน", .setupProgress: "ความคืบหน้าการตั้งค่า",
        .preparingGateway: "กำลังเตรียมเกตเวย์", .testingTunnel: "กำลังทดสอบอุโมงค์", .profile: "โปรไฟล์",
        .authentication: "การยืนยันตัวตน", .passwordKeychain: "รหัสผ่าน / คลังกุญแจ", .ed25519Key: "คีย์ Ed25519",
        .error: "ข้อผิดพลาด", .technicalDetails: "รายละเอียดทางเทคนิค", .diagnosticsTitle: "การวินิจฉัย",
        .noServer: "ไม่มีเซิร์ฟเวอร์", .setupFailed: "การตั้งค่า VPN ล้มเหลว", .selectedServer: "เซิร์ฟเวอร์ที่เลือก",
        .ping: "Ping", .status: "สถานะ", .country: "ประเทศ", .ip: "IP", .settings: "ตั้งค่า",
        .sshConnectionFailed: "การเชื่อมต่อ SSH ล้มเหลว", .sshHostKeyMismatch: "คีย์โฮสต์ไม่ตรงกัน",
        .sshAuthFailed: "การยืนยันตัวตนล้มเหลว", .sshTimeout: "การเชื่อมต่อหมดเวลา",
        .unknownError: "ข้อผิดพลาดที่ไม่รู้จัก"
    ]

    // MARK: - Turkish
    private let turkish: [CopyKey: String] = [
        .chooseLanguage: "Dilinizi seçin", .selectLanguageHint: "SSH2VPN dilini seçin", .connected: "Bağlandı",
        .connecting: "Bağlanıyor…", .disconnected: "Bağlantı kesildi", .connect: "Bağlan", .disconnect: "Bağlantıyı kes",
        .ready: "Hazır", .yourVPS: "VPS'niz", .addExistingServer: "Mevcut sunucu ekle", .addServer: "Sunucu ekle",
        .server: "Sunucu", .protected_: "Korumalı", .unprotected: "Korumasız",
        .address: "IP adresi veya ana bilgisayar adı", .username: "Kullanıcı adı", .sshPort: "SSH portu",
        .testConnection: "Bağlantıyı test et", .passwordOptional: "Şifre (isteğe bağlı)",
        .ed25519PrivateKeyOptional: "Ed25519 özel anahtarı (isteğe bağlı)",
        .ed25519Hint: "Şifrelenmemiş OpenSSH Ed25519 veya ham 32 bayt base64/hex tohumu. Şifreli anahtarlar açıkça reddedilir.",
        .pinnedHostKey: "Sabitlenmiş OpenSSH ana bilgisayar anahtarı",
        .credentialsHint: "Kimlik bilgileriniz yalnızca VPS'nize bağlanmak için kullanılır.",
        .addServerTitle: "Sunucu ekle", .cancel: "İptal", .invalidInput: "Geçersiz giriş", .ok: "Tamam",
        .addressPlaceholder: "192.168.1.1 veya vpn.ornek.com", .portPlaceholder: "22", .usernamePlaceholder: "root",
        .passwordPlaceholder: "Şifre", .privateKeyPlaceholder: "OpenSSH özel anahtarını yapıştırın...",
        .hostKeyPlaceholder: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5...", .languageSection: "Dil",
        .diagnosticsSection: "Tanılama", .connectionDiagnostics: "Bağlantı tanılama", .vpnSettings: "VPN Ayarları",
        .protocolTitle: "Protokol", .dnsSettings: "DNS Ayarları", .advanced: "Gelişmiş",
        .protocolDesc: "VPN protokolü seçin", .dnsDesc: "DNS sunucularını yapılandırın",
        .advancedDesc: "Gelişmiş ayarlar", .locations: "Konumlar", .yourServer: "Sunucunuz",
        .noServerConfigured: "Yapılandırılmış sunucu yok", .addServerLabel: "Sunucu ekle",
        .addServerDesc: "Kendi VPS'nize bağlanın", .active: "Aktif", .about: "Hakkında", .version: "Sürüm",
        .setupProgress: "Kurulum ilerlemesi", .preparingGateway: "Ağ geçidi hazırlanıyor",
        .testingTunnel: "Tunnel test ediliyor", .profile: "Profil", .authentication: "Kimlik doğrulama",
        .passwordKeychain: "Şifre / Anahtar Zinciri", .ed25519Key: "Ed25519 anahtarı", .error: "Hata",
        .technicalDetails: "Teknik ayrıntılar", .diagnosticsTitle: "Tanılama", .noServer: "Sunucu yok",
        .setupFailed: "VPN kurulumu başarısız", .selectedServer: "Seçilen sunucu", .ping: "Ping", .status: "Durum",
        .country: "Ülke", .ip: "IP", .settings: "Ayarlar", .sshConnectionFailed: "SSH bağlantısı başarısız",
        .sshHostKeyMismatch: "Ana bilgisayar anahtarı eşleşmiyor", .sshAuthFailed: "Kimlik doğrulama başarısız",
        .sshTimeout: "Bağlantı zaman aşımı", .unknownError: "Bilinmeyen hata"
    ]

    // MARK: - Polish
    private let polish: [CopyKey: String] = [
        .chooseLanguage: "Wybierz język", .selectLanguageHint: "Wybierz język SSH2VPN", .connected: "Połączono",
        .connecting: "Łączenie…", .disconnected: "Rozłączono", .connect: "Połącz", .disconnect: "Rozłącz",
        .ready: "Gotowy", .yourVPS: "Twój VPS", .addExistingServer: "Dodaj istniejący serwer",
        .addServer: "Dodaj serwer", .server: "Serwer", .protected_: "Chroniony", .unprotected: "Niechroniony",
        .address: "Adres IP lub nazwa hosta", .username: "Nazwa użytkownika", .sshPort: "Port SSH",
        .testConnection: "Testuj połączenie", .passwordOptional: "Hasło (opcjonalnie)",
        .ed25519PrivateKeyOptional: "Klucz prywatny Ed25519 (opcjonalnie)",
        .ed25519Hint: "Niezaszyfrowany OpenSSH Ed25519 lub surowy 32-bajtowy seed base64/hex. Zaszyfrowane klucze są jawnie odrzucane.",
        .pinnedHostKey: "Przypięty klucz hosta OpenSSH",
        .credentialsHint: "Twoje dane uwierzytelniające służą tylko do połączenia z VPS.",
        .addServerTitle: "Dodaj serwer", .cancel: "Anuluj", .invalidInput: "Nieprawidłowe dane", .ok: "OK",
        .addressPlaceholder: "192.168.1.1 lub vpn.przyklad.pl", .portPlaceholder: "22", .usernamePlaceholder: "root",
        .passwordPlaceholder: "Hasło", .privateKeyPlaceholder: "Wklej klucz prywatny OpenSSH...",
        .hostKeyPlaceholder: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5...", .languageSection: "Język",
        .diagnosticsSection: "Diagnostyka", .connectionDiagnostics: "Diagnostyka połączenia",
        .vpnSettings: "Ustawienia VPN", .protocolTitle: "Protokół", .dnsSettings: "Ustawienia DNS",
        .advanced: "Zaawansowane", .protocolDesc: "Wybierz protokół VPN", .dnsDesc: "Konfiguruj serwery DNS",
        .advancedDesc: "Ustawienia zaawansowane", .locations: "Lokalizacje", .yourServer: "Twój serwer",
        .noServerConfigured: "Brak skonfigurowanego serwera", .addServerLabel: "Dodaj serwer",
        .addServerDesc: "Połącz się z własnym VPS", .active: "Aktywny", .about: "O aplikacji", .version: "Wersja",
        .setupProgress: "Postęp konfiguracji", .preparingGateway: "Przygotowywanie bramki",
        .testingTunnel: "Testowanie tunelu", .profile: "Profil", .authentication: "Uwierzytelnianie",
        .passwordKeychain: "Hasło / Pęklarz kluczy", .ed25519Key: "Klucz Ed25519", .error: "Błąd",
        .technicalDetails: "Szczegóły techniczne", .diagnosticsTitle: "Diagnostyka", .noServer: "Brak serwera",
        .setupFailed: "Konfiguracja VPN nie powiodła się", .selectedServer: "Wybrany serwer", .ping: "Ping",
        .status: "Status", .country: "Kraj", .ip: "IP", .settings: "Ustawienia",
        .sshConnectionFailed: "Połączenie SSH nie powiodło się", .sshHostKeyMismatch: "Klucz hosta nie pasuje",
        .sshAuthFailed: "Uwierzytelnianie nie powiodło się", .sshTimeout: "Przekroczono limit czasu połączenia",
        .unknownError: "Nieznany błąd"
    ]

    // MARK: - Dutch
    private let dutch: [CopyKey: String] = [
        .chooseLanguage: "Kies je taal", .selectLanguageHint: "Selecteer de taal van SSH2VPN", .connected: "Verbonden",
        .connecting: "Verbinden…", .disconnected: "Verbinding verbroken", .connect: "Verbinden",
        .disconnect: "Verbinding verbreken", .ready: "Gereed", .yourVPS: "Je VPS",
        .addExistingServer: "Bestaande server toevoegen", .addServer: "Server toevoegen", .server: "Server",
        .protected_: "Beschermd", .unprotected: "Onbeschermd", .address: "IP-adres of hostnaam",
        .username: "Gebruikersnaam", .sshPort: "SSH-poort", .testConnection: "Verbinding testen",
        .passwordOptional: "Wachtwoord (optioneel)", .ed25519PrivateKeyOptional: "Ed25519 privésleutel (optioneel)",
        .ed25519Hint: "Onversleutelde OpenSSH Ed25519 of raw 32-byte base64/hex seed. Versleutelde sleutels worden expliciet geweigerd.",
        .pinnedHostKey: "Vastgezette OpenSSH hostsleutel",
        .credentialsHint: "Je gegevens worden alleen gebruikt om verbinding te maken met je VPS.",
        .addServerTitle: "Server toevoegen", .cancel: "Annuleren", .invalidInput: "Ongeldige invoer", .ok: "OK",
        .addressPlaceholder: "192.168.1.1 of vpn.voorbeeld.nl", .portPlaceholder: "22", .usernamePlaceholder: "root",
        .passwordPlaceholder: "Wachtwoord", .privateKeyPlaceholder: "Plak OpenSSH privésleutel...",
        .hostKeyPlaceholder: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5...", .languageSection: "Taal",
        .diagnosticsSection: "Diagnostiek", .connectionDiagnostics: "Verbindingsdiagnostiek",
        .vpnSettings: "VPN-instellingen", .protocolTitle: "Protocol", .dnsSettings: "DNS-instellingen",
        .advanced: "Geavanceerd", .protocolDesc: "Selecteer VPN-protocol", .dnsDesc: "Configureer DNS-servers",
        .advancedDesc: "Geavanceerde instellingen", .locations: "Locaties", .yourServer: "Je server",
        .noServerConfigured: "Geen server geconfigureerd", .addServerLabel: "Server toevoegen",
        .addServerDesc: "Verbind met je eigen VPS", .active: "Actief", .about: "Over", .version: "Versie",
        .setupProgress: "Installatievoortgang", .preparingGateway: "Gateway voorbereiden",
        .testingTunnel: "Tunnel testen", .profile: "Profiel", .authentication: "Authenticatie",
        .passwordKeychain: "Wachtwoord / Sleutelbos", .ed25519Key: "Ed25519 sleutel", .error: "Fout",
        .technicalDetails: "Technische details", .diagnosticsTitle: "Diagnostiek", .noServer: "Geen server",
        .setupFailed: "VPN-configuratie mislukt", .selectedServer: "Geselecteerde server", .ping: "Ping",
        .status: "Status", .country: "Land", .ip: "IP", .settings: "Instellingen",
        .sshConnectionFailed: "SSH-verbinding mislukt", .sshHostKeyMismatch: "Hostsleutel komt niet overeen",
        .sshAuthFailed: "Authenticatie mislukt", .sshTimeout: "Verbinding time-out", .unknownError: "Onbekende fout"
    ]

    // MARK: - Vietnamese
    private let vietnamese: [CopyKey: String] = [
        .chooseLanguage: "Chọn ngôn ngữ", .selectLanguageHint: "Chọn ngôn ngữ cho SSH2VPN", .connected: "Đã kết nối",
        .connecting: "Đang kết nối…", .disconnected: "Đã ngắt kết nối", .connect: "Kết nối", .disconnect: "Ngắt kết nối",
        .ready: "Sẵn sàng", .yourVPS: "VPS của bạn", .addExistingServer: "Thêm server hiện có",
        .addServer: "Thêm server", .server: "Server", .protected_: "Được bảo vệ", .unprotected: "Không được bảo vệ",
        .address: "Địa chỉ IP hoặc tên host", .username: "Tên người dùng", .sshPort: "Cổng SSH",
        .testConnection: "Kiểm tra kết nối", .passwordOptional: "Mật khẩu (tùy chọn)",
        .ed25519PrivateKeyOptional: "Khóa riêng Ed25519 (tùy chọn)",
        .ed25519Hint: "OpenSSH Ed25519 chưa mã hóa hoặc hạt giống raw 32 byte base64/hex. Khóa mã hóa bị từ chối rõ ràng.",
        .pinnedHostKey: "Khóa host OpenSSH đã ghim",
        .credentialsHint: "Thông tin đăng nhập chỉ được dùng để kết nối với VPS của bạn.",
        .addServerTitle: "Thêm server", .cancel: "Hủy", .invalidInput: "Dữ liệu không hợp lệ", .ok: "OK",
        .addressPlaceholder: "192.168.1.1 hoặc vpn.example.com", .portPlaceholder: "22", .usernamePlaceholder: "root",
        .passwordPlaceholder: "Mật khẩu", .privateKeyPlaceholder: "Dán khóa riêng OpenSSH...",
        .hostKeyPlaceholder: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5...", .languageSection: "Ngôn ngữ",
        .diagnosticsSection: "Chẩn đoán", .connectionDiagnostics: "Chẩn đoán kết nối", .vpnSettings: "Cài đặt VPN",
        .protocolTitle: "Giao thức", .dnsSettings: "Cài đặt DNS", .advanced: "Nâng cao",
        .protocolDesc: "Chọn giao thức VPN", .dnsDesc: "Cấu hình máy chủ DNS", .advancedDesc: "Cài đặt nâng cao",
        .locations: "Vị trí máy chủ", .yourServer: "Máy chủ của bạn", .noServerConfigured: "Chưa cấu hình máy chủ",
        .addServerLabel: "Thêm server", .addServerDesc: "Kết nối với VPS của bạn", .active: "Hoạt động",
        .about: "Giới thiệu", .version: "Phiên bản", .setupProgress: "Tiến trình thiết lập",
        .preparingGateway: "Đang chuẩn bị cổng", .testingTunnel: "Đang kiểm tra đường hầm", .profile: "Hồ sơ",
        .authentication: "Xác thực", .passwordKeychain: "Mật khẩu / Chìa khóa", .ed25519Key: "Khóa Ed25519",
        .error: "Lỗi", .technicalDetails: "Chi tiết kỹ thuật", .diagnosticsTitle: "Chẩn đoán",
        .noServer: "Không có server", .setupFailed: "Thiết lập VPN thất bại", .selectedServer: "Server đã chọn",
        .ping: "Ping", .status: "Trạng thái", .country: "Quốc gia", .ip: "IP", .settings: "Cài đặt",
        .sshConnectionFailed: "Kết nối SSH thất bại", .sshHostKeyMismatch: "Khóa host không khớp",
        .sshAuthFailed: "Xác thực thất bại", .sshTimeout: "Hết thời gian kết nối", .unknownError: "Lỗi không xác định"
    ]

}
