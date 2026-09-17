package com.ssh2vpn.android.data

import kotlinx.serialization.Serializable

/** Один SSH-сервер — зеркало ServerProfile (iOS). Секреты — только в EncryptedSharedPreferences. */
@Serializable
data class ServerProfile(
    val id: String,
    val name: String,
    val label: String? = null,
    val host: String,
    val port: Int = 22,
    val username: String,
    val hostKey: String = "",
    val dnsServers: List<String> = emptyList(),
    val hasPassword: Boolean = false,
    val hasPrivateKey: Boolean = false
) {
    /** Алиас; nil/пусто = нет алиаса (UI показывает host:port). Порт normalizedLabel. */
    val displayLabel: String? get() = label?.takeIf { it.isNotBlank() }
    val hasCustomLabel: Boolean get() = displayLabel != null
    /** Подзаголовок списков: алиас если есть, иначе host:port. */
    val displayAddress: String get() = displayLabel ?: "$host:$port"
}

@Serializable
internal data class ServerSecrets(val password: String? = null, val privateKey: String? = null)

@Serializable
data class DnsRuleDto(val domain: String, val kind: String, val ip: String = "", val sub: Boolean = true)

/** Настройки Protocol/DNS/Advanced — зеркало AppSettingsState (protocol всегда SSH2). */@Serializable
data class AppSettings(
    val protocolName: String = "SSH2",
    val useCustomDns: Boolean = false,
    val primaryDns: String = "1.1.1.1",
    val secondaryDns: String = "8.8.8.8",
    val killSwitch: Boolean = true,
    val connectOnDemand: Boolean = false,
    val enableLogging: Boolean = false,
    val dnsRules: List<DnsRuleDto> = emptyList(),
    val presetDns: List<String> = emptyList()
) {
    val resolvedDnsServers: List<String>
        get() = when {
            presetDns.isNotEmpty() -> presetDns
            !useCustomDns -> emptyList()
            else -> listOf(primaryDns, secondaryDns).filter { it.isNotBlank() }
        }
    val validatedDnsServers: List<String> get() = resolvedDnsServers.filter { isValidIpv4(it) }

    companion object {
        fun isValidIpv4(s: String): Boolean {
            val p = s.trim().split(".")
            if (p.size != 4) return false
            return p.all { q -> q.isNotEmpty() && q.length <= 3 && q.all { it.isDigit() } && (q.toIntOrNull() ?: -1) in 0..255 }
        }
    }
}

/**
 * Квота бесплатного времени — порт QuotaLedger.swift 1-в-1 (чистая, без Android):
 * 1ч при ПЕРВОМ использовании (не install), +3ч за rewarded (кулдаун 1ч, cap 12ч),
 * тикает wall-clock даже при выключенном VPN, Unlimited снимает лимит и рекламу.
 */
data class QuotaLedger(
    val unlimited: Boolean = false,
    val expiresAt: Long? = null,
    val lastAdViewAt: Long? = null
) {
    companion object {
        const val INITIAL_GRANT_SEC = 3600L
        const val AD_REWARD_SEC = 3 * 3600L
        const val AD_COOLDOWN_SEC = 3600L
        const val MAX_BUDGET_SEC = 12 * 3600L
    }
    fun remainingSec(now: Long = System.currentTimeMillis()): Long {
        if (unlimited) return Long.MAX_VALUE
        val e = expiresAt ?: return 0
        return maxOf(0, (e - now) / 1000)
    }
    fun allowsConnection(now: Long = System.currentTimeMillis()): Boolean =
        unlimited || remainingSec(now) > 0
    fun withInitialGrant(now: Long = System.currentTimeMillis()): QuotaLedger =
        if (unlimited || expiresAt != null) this else copy(expiresAt = now + INITIAL_GRANT_SEC * 1000)
    /** null = засчитать нельзя (unlimited / кулдаун / cap). */
    fun creditingAdView(now: Long = System.currentTimeMillis()): QuotaLedger? {
        if (unlimited) return null
        if (lastAdViewAt != null && now - lastAdViewAt < AD_COOLDOWN_SEC * 1000) return null
        if (remainingSec(now) >= MAX_BUDGET_SEC) return null
        val base = maxOf(now, expiresAt ?: now)
        val ext = minOf(base + AD_REWARD_SEC * 1000, now + MAX_BUDGET_SEC * 1000)
        return copy(expiresAt = ext, lastAdViewAt = now)
    }
    fun withUnlimited(): QuotaLedger = copy(unlimited = true, expiresAt = null)
    fun removingUnlimited(): QuotaLedger = copy(unlimited = false)
}
