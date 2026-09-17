package com.ssh2vpn.android.ui

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.ssh2vpn.android.ads.AdsManager
import com.ssh2vpn.android.billing.StoreManager
import com.ssh2vpn.android.core.DnsPresets
import com.ssh2vpn.android.core.DnsRule
import com.ssh2vpn.android.core.DnsRuleKind
import com.ssh2vpn.android.core.HostKeyValidator
import com.ssh2vpn.android.core.LocalDnsFilter
import com.ssh2vpn.android.core.OfflineGeoIP
import com.ssh2vpn.android.core.PingBudget
import com.ssh2vpn.android.core.ProfileError
import com.ssh2vpn.android.core.ProfileValidator
import com.ssh2vpn.android.core.SshStartError
import com.ssh2vpn.android.data.AppLanguage
import com.ssh2vpn.android.data.AppSettings
import com.ssh2vpn.android.data.ConsoleLog
import com.ssh2vpn.android.data.DnsListStore
import com.ssh2vpn.android.data.DnsRuleDto
import com.ssh2vpn.android.data.LanguageStore
import com.ssh2vpn.android.data.QuotaLedger
import com.ssh2vpn.android.data.QuotaStore
import com.ssh2vpn.android.data.ServerProfile
import com.ssh2vpn.android.data.ServerStore
import com.ssh2vpn.android.data.SettingsStore
import com.ssh2vpn.android.ssh.SshConnectionPool
import com.ssh2vpn.android.ssh.SshCredentials
import com.ssh2vpn.android.ssh.SshKeyParser
import com.ssh2vpn.android.vpn.LiveDnsConfig
import com.ssh2vpn.android.vpn.SshVpnService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.UUID

/** Строка списка серверов: профиль + гео + пинг. */
data class ServerRow(
    val profile: ServerProfile,
    val countryCode: String?,
    val flag: String,
    val pingMs: Int?
)

/**
 * Состояние приложения — зеркало AppModel (iOS): серверы, настройки, квота,
 * фазы, гео/пинги, paywall-стадия, privacy-гейт.
 */
class AppViewModel(ctx: Context) : ViewModel() {
    private val appCtx = ctx.applicationContext
    private val servers = ServerStore(appCtx)
    private val quotaStore = QuotaStore(appCtx)
    private val settingsStore = SettingsStore(appCtx)
    val lists = DnsListStore(appCtx)
    val lang = LanguageStore(appCtx)

    val ads = AdsManager(appCtx, viewModelScope)
    val store = StoreManager(appCtx, viewModelScope)
    private val pingBudget = PingBudget()

    private val _serverList = MutableStateFlow<List<ServerProfile>>(emptyList())
    val serverList: StateFlow<List<ServerProfile>> = _serverList
    private val _rows = MutableStateFlow<List<ServerRow>>(emptyList())
    val rows: StateFlow<List<ServerRow>> = _rows
    private val _selectedId = MutableStateFlow<String?>(null)
    val selectedId: StateFlow<String?> = _selectedId
    private val _settings = MutableStateFlow(AppSettings())
    val settings: StateFlow<AppSettings> = _settings
    private val _quota = MutableStateFlow(QuotaLedger())
    val quota: StateFlow<QuotaLedger> = _quota
    private val _testing = MutableStateFlow<String?>(null)
    val testing: StateFlow<String?> = _testing
    private val _paywallStage = MutableStateFlow("discount")
    val paywallStage: StateFlow<String> = _paywallStage
    private val _privacyAck = MutableStateFlow(true)
    val privacyAck: StateFlow<Boolean> = _privacyAck
    private val _subs = MutableStateFlow<List<com.ssh2vpn.android.data.SubscribedList>>(emptyList())
    val subs: StateFlow<List<com.ssh2vpn.android.data.SubscribedList>> = _subs
    val logLines get() = ConsoleLog.lines

    val phase: StateFlow<String> = SshVpnService.phase
    val stats: StateFlow<SshVpnService.Stats> = SshVpnService.stats
    val lastError: StateFlow<String?> = SshVpnService.lastError
    val lastErrorCode: StateFlow<String?> = SshVpnService.lastErrorCode

    private val pingCache = mutableMapOf<String, Int?>()
    private var geoLoaded = false

    init {
        viewModelScope.launch(Dispatchers.IO) {
            loadGeo()
            servers.dedupe()
            refresh()
        }
    }

    private fun loadGeo() {
        if (geoLoaded) return
        geoLoaded = true
        try {
            val bytes = appCtx.assets.open("geoip.dat").use { it.readBytes() }
            val ok = OfflineGeoIP.load(bytes)
            ConsoleLog.log("info", "GEO", "geoip.dat: ${OfflineGeoIP.loadedPrefixCount ?: "?"} префиксов (ok=$ok)")
        } catch (e: Exception) {
            ConsoleLog.log("warn", "GEO", "geoip.dat не загружен: ${e.message}")
        }
    }

    suspend fun refresh() {
        _serverList.value = servers.loadAll()
        _selectedId.value = servers.selectedId() ?: _serverList.value.firstOrNull()?.id
        _settings.value = settingsStore.load()
        _quota.value = quotaStore.load()
        _subs.value = lists.subscribed()
        _privacyAck.value = appCtx.getSharedPreferences("app", Context.MODE_PRIVATE)
            .getBoolean("privacy_ack_v1", false)
        _paywallStage.value = if (appCtx.getSharedPreferences("app", Context.MODE_PRIVATE)
                .getBoolean("paywall_intro_seen", false)) "full" else "discount"
        ads.refreshCooldown()
        rebuildRows()
    }

    fun refreshAsync() = viewModelScope.launch(Dispatchers.IO) { refresh() }

    fun ackPrivacy() {
        appCtx.getSharedPreferences("app", Context.MODE_PRIVATE).edit().putBoolean("privacy_ack_v1", true).apply()
        _privacyAck.value = true
    }

    fun markPaywallSeen() {
        appCtx.getSharedPreferences("app", Context.MODE_PRIVATE).edit().putBoolean("paywall_intro_seen", true).apply()
        _paywallStage.value = "full"
    }

    // ---------- Серверы ----------

    private suspend fun rebuildRows() {
        val list = _serverList.value
        _rows.value = withContext(Dispatchers.IO) {
            list.map { p ->
                val cc = if (OfflineGeoIP.isLocalOrPrivate(p.host)) null
                else try { OfflineGeoIP.countryCodeForHost(p.host) } catch (_: Exception) { null }
                ServerRow(p, cc, cc?.let { OfflineGeoIP.flagEmoji(it) } ?: "🌐", pingCache[p.id])
            }
        }
        // Декоративные пинги — через бюджет (не DoSим свой VPS).
        for (r in _rows.value) {
            if (r.pingMs == null && pingBudget.allow()) {
                viewModelScope.launch(Dispatchers.IO) {
                    val ms = tcpPing(r.profile.host, r.profile.port)
                    pingCache[r.profile.id] = ms
                    _rows.value = _rows.value.map { if (it.profile.id == r.profile.id) it.copy(pingMs = ms) else it }
                }
            }
        }
    }

    /** TCP-пинг порта (декоративный): SYN→ACK замер, без SSH. */
    internal fun tcpPing(host: String, port: Int, timeoutMs: Int = 3000): Int? {
        return try {
            val t0 = System.currentTimeMillis()
            java.net.Socket().use { s ->
                s.tcpNoDelay = true
                s.connect(java.net.InetSocketAddress(host, port), timeoutMs)
            }
            (System.currentTimeMillis() - t0).toInt()
        } catch (_: Exception) { null }
    }

    fun select(id: String) = viewModelScope.launch(Dispatchers.IO) {
        servers.select(id); _selectedId.value = id
    }

    // ---------- Настройки + живой пуш DNS ----------

    fun saveSettings(s: AppSettings) = viewModelScope.launch(Dispatchers.IO) {
        val norm = if (s.presetDns.isNotEmpty()) s.copy(useCustomDns = false) else s
        settingsStore.save(norm); _settings.value = norm
        pushLiveDns()
    }

    fun applyPreset(id: String?) = viewModelScope.launch(Dispatchers.IO) {
        val cur = settingsStore.load()
        if (id == null) {
            val next = cur.copy(presetDns = emptyList())
            settingsStore.save(next); _settings.value = next
        } else {
            val p = DnsPresets.all.firstOrNull { it.id == id } ?: return@launch
            val next = cur.copy(useCustomDns = false, presetDns = listOf(p.primary, p.secondary))
            settingsStore.save(next); _settings.value = next
        }
        pushLiveDns()
    }

    fun addDnsRule(domain: String, kind: String, ip: String, sub: Boolean): String? {
        if (LocalDnsFilter.normalize(domain) == null) return "dnsInvalidDomain"
        if (kind == "override" && !AppSettings.isValidIpv4(ip)) return "dnsInvalidIP"
        viewModelScope.launch(Dispatchers.IO) {
            val cur = settingsStore.load()
            if (cur.dnsRules.any { it.domain.equals(domain.trim(), true) && it.kind == kind }) return@launch
            val next = cur.copy(dnsRules = cur.dnsRules + DnsRuleDto(domain.trim().lowercase(), kind, ip.trim(), sub))
            settingsStore.save(next); _settings.value = next
            pushLiveDns()
        }
        return null
    }

    fun removeDnsRule(domain: String, kind: String) = viewModelScope.launch(Dispatchers.IO) {
        val cur = settingsStore.load()
        val next = cur.copy(dnsRules = cur.dnsRules.filterNot { it.domain == domain && it.kind == kind })
        settingsStore.save(next); _settings.value = next
        pushLiveDns()
    }

    fun pushLiveDns() {
        viewModelScope.launch(Dispatchers.IO) {
            val cur = settingsStore.load()
            val rules = cur.dnsRules.map {
                DnsRule(it.domain, if (it.kind == "override") DnsRuleKind.OVERRIDE else DnsRuleKind.BLOCK, it.ip, it.sub)
            }
            SshVpnService.liveDns.value = LiveDnsConfig(LocalDnsFilter(rules), cur.validatedDnsServers.ifEmpty { listOf("8.8.8.8", "1.1.1.1") })
        }
    }

    fun setLogging(on: Boolean) = viewModelScope.launch(Dispatchers.IO) {
        ConsoleLog.enabled = on
        val cur = settingsStore.load()
        val next = cur.copy(enableLogging = on)
        settingsStore.save(next); _settings.value = next
    }

    // ---------- Списки ----------

    fun subscribeList(id: String) = viewModelScope.launch(Dispatchers.IO) {
        lists.subscribe(id); _subs.value = lists.subscribed(); pushLiveDns(); refreshAsync()
    }
    fun unsubscribeList(id: String) = viewModelScope.launch(Dispatchers.IO) {
        lists.unsubscribe(id); _subs.value = lists.subscribed(); pushLiveDns()
    }
    fun refreshList(id: String) = viewModelScope.launch(Dispatchers.IO) {
        lists.refresh(id); _subs.value = lists.subscribed(); pushLiveDns()
    }

    // ---------- Тест и сохранение сервера ----------

    /**
     * Тест: валидация → SSH reachable + auth → forwarding probe.
     * manualHostKey: ручной ввод (валидируется, имеет приоритет над TOFU).
     */
    fun testAndSave(
        id: String?, name: String, host: String, port: Int, username: String,
        password: String?, privateKeyPem: String?, manualHostKey: String?,
        label: String?, cb: (ok: Boolean, msg: String) -> Unit
    ) {
        val h: String
        val u: String
        try {
            h = ProfileValidator.validateHost(host)
            ProfileValidator.validatePort(port.toString())
            u = ProfileValidator.validateUsername(username)
            ProfileValidator.requireAuth(password, privateKeyPem)
        } catch (e: ProfileError) {
            cb(false, e.message ?: "invalid input"); return
        }
        var pinnedManual: String? = null
        if (!manualHostKey.isNullOrBlank()) {
            try {
                pinnedManual = HostKeyValidator.validate(manualHostKey)
            } catch (e: Exception) {
                cb(false, e.message ?: "bad host key"); return
            }
        }
        if (!privateKeyPem.isNullOrBlank()) {
            try {
                com.ssh2vpn.android.ssh.SshKeyParser.normalizeEd25519Seed(privateKeyPem)
            } catch (e: Exception) {
                cb(false, e.message ?: "bad key"); return
            }
        }
        _testing.value = "testing"
        viewModelScope.launch(Dispatchers.IO) {
            var pinned: String? = pinnedManual
            val pool = SshConnectionPool(
                creds = { SshCredentials(h, port, u, password, privateKeyPem, pinnedManual) },
                onFirstPin = { if (pinned == null) pinned = it }
            )
            pool.connectFirst { ok, err ->
                viewModelScope.launch(Dispatchers.IO) {
                    if (!ok) {
                        val msg = "${err?.message} [${err?.code}]"
                        _testing.value = "err:$msg"
                        cb(false, msg)
                        pool.closeAll()
                        return@launch
                    }
                    val sid = id ?: UUID.randomUUID().toString()
                    val cleanLabel = com.ssh2vpn.android.core.TextInput.sanitizeLabel(label)
                    val prof = ServerProfile(
                        id = sid,
                        name = name.ifBlank { "$h:$port" },
                        label = cleanLabel,
                        host = h, port = port, username = u,
                        hostKey = pinned ?: "",
                        hasPassword = !password.isNullOrEmpty(),
                        hasPrivateKey = !privateKeyPem.isNullOrEmpty()
                    )
                    servers.save(prof, password?.ifBlank { null }, privateKeyPem?.ifBlank { null })
                    servers.select(sid)
                    pool.closeAll()
                    refresh()
                    _testing.value = "ok:SSH OK, forwarding probe OK"
                    cb(true, "SSH connection successful, tunnel supported")
                }
            }
        }
    }

    fun deleteServer(id: String) = viewModelScope.launch(Dispatchers.IO) {
        servers.delete(id); pingCache.remove(id); refresh()
    }
}
