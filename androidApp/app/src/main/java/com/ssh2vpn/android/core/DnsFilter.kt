package com.ssh2vpn.android.core

/** DNS wire-утилиты — порт DNSWire из iOS 1-в-1 (без изменений семантики). */
object DnsWire {
    fun questionName(message: ByteArray): String? {
        if (message.size < 12) return null
        val labels = mutableListOf<String>()
        var i = 12
        while (i < message.size) {
            val len = message[i].toInt() and 0xFF
            if (len == 0) break
            i++
            if (i + len > message.size) return null
            labels.add(String(message, i, len, Charsets.UTF_8).lowercase())
            i += len
            if (labels.size > 128) return null
        }
        if (labels.isEmpty()) return null
        return labels.joinToString(".")
    }

    fun questionType(message: ByteArray): Int? {
        if (message.size < 12) return null
        var i = 12
        while (i < message.size && message[i].toInt() != 0) i += (message[i].toInt() and 0xFF) + 1
        if (i + 5 > message.size || message[i].toInt() != 0) return null
        return (((message[i + 1].toInt() and 0xFF) shl 8) or (message[i + 2].toInt() and 0xFF))
    }

    fun ipv4Bytes(s: String): ByteArray? {
        val parts = s.trim().split(".", limit = 4)
        if (parts.size != 4) return null
        val out = ByteArray(4)
        for ((idx, p) in parts.withIndex()) {
            if (p.isEmpty() || p.length > 3 || !p.all { it.isDigit() }) return null
            val v = p.toIntOrNull() ?: return null
            if (v !in 0..255) return null
            out[idx] = v.toByte()
        }
        return out
    }

    fun aRecordReply(query: ByteArray, ipv4: ByteArray, ttl: Long = 300): ByteArray? {
        if (query.size < 12 || ipv4.size != 4) return null
        var i = 12
        while (i < query.size && query[i].toInt() != 0) i += (query[i].toInt() and 0xFF) + 1
        if (i + 5 > query.size || query[i].toInt() != 0) return null
        val qEnd = i + 5
        val out = mutableListOf<Byte>()
        out.add(query[0]); out.add(query[1])
        out.add(0x81.toByte()); out.add(0x80.toByte())
        out.add(0); out.add(1); out.add(0); out.add(1)
        out.add(0); out.add(0); out.add(0); out.add(0)
        for (k in 12 until qEnd) out.add(query[k])
        out.add(0xC0.toByte()); out.add(0x0C.toByte())
        out.add(0); out.add(1); out.add(0); out.add(1)
        out.add(((ttl shr 24) and 0xFF).toByte()); out.add(((ttl shr 16) and 0xFF).toByte())
        out.add(((ttl shr 8) and 0xFF).toByte()); out.add((ttl and 0xFF).toByte())
        out.add(0); out.add(4)
        ipv4.forEach { out.add(it) }
        return out.toByteArray()
    }

    fun refusedReply(query: ByteArray): ByteArray? {
        if (query.size < 12) return null
        val out = query.copyOf()
        out[2] = 0x80.toByte(); out[3] = 0x05.toByte()
        out[6] = 0; out[7] = 0; out[8] = 0; out[9] = 0; out[10] = 0; out[11] = 0
        return out
    }
}

enum class DnsRuleKind { BLOCK, OVERRIDE }

data class DnsRule(
    val domain: String,
    val kind: DnsRuleKind,
    val ip: String = "",
    val includeSubdomains: Boolean = true
)

sealed class LocalDnsAction {
    object None : LocalDnsAction()
    object Blocked : LocalDnsAction()
    data class Override(val ip: String) : LocalDnsAction()
}

/** Локальный DNS-фильтр — порт LocalDNSFilter.swift (приоритеты и нормализация те же). */
class LocalDnsFilter(
    exactBlocks: Set<String> = emptySet(),
    subtreeBlocks: Set<String> = emptySet(),
    exactOverrides: Map<String, String> = emptyMap(),
    subtreeOverrides: Map<String, String> = emptyMap()
) {
    private val exactBlocks: Set<String>
    private val subtreeBlocks: Set<String>
    private val exactOverrides: Map<String, String>
    private val subtreeOverrides: Map<String, String>

    init {
        this.exactBlocks = exactBlocks.mapNotNull { normalize(it) }.filter { it.isNotEmpty() }.toSet()
        this.subtreeBlocks = subtreeBlocks.mapNotNull { normalize(it) }.filter { it.isNotEmpty() }.toSet()
        this.exactOverrides = cleanOverrides(exactOverrides)
        this.subtreeOverrides = cleanOverrides(subtreeOverrides)
    }

    constructor(entries: List<DnsRule>) : this(
        exactBlocks = entries.filter { it.kind == DnsRuleKind.BLOCK && !it.includeSubdomains }
            .mapNotNull { normalize(it.domain) }.toSet(),
        subtreeBlocks = entries.filter { it.kind == DnsRuleKind.BLOCK && it.includeSubdomains }
            .mapNotNull { normalize(it.domain) }.toSet(),
        exactOverrides = entries.filter { it.kind == DnsRuleKind.OVERRIDE && !it.includeSubdomains && DnsWire.ipv4Bytes(it.ip) != null }
            .associate { normalize(it.domain)!! to it.ip },
        subtreeOverrides = entries.filter { it.kind == DnsRuleKind.OVERRIDE && it.includeSubdomains && DnsWire.ipv4Bytes(it.ip) != null }
            .associate { normalize(it.domain)!! to it.ip }
    )

    fun actionFor(domain: String): LocalDnsAction {
        val d = normalize(domain) ?: return LocalDnsAction.None
        if (d.isEmpty()) return LocalDnsAction.None
        exactOverrides[d]?.let { return LocalDnsAction.Override(it) }
        if (exactBlocks.contains(d)) return LocalDnsAction.Blocked
        subtreeOverrides[d]?.let { return LocalDnsAction.Override(it) }
        if (subtreeBlocks.contains(d)) return LocalDnsAction.Blocked
        val parts = d.split(".").toMutableList()
        while (parts.size > 1) {
            parts.removeAt(0)
            val anc = parts.joinToString(".")
            subtreeOverrides[anc]?.let { return LocalDnsAction.Override(it) }
            if (subtreeBlocks.contains(anc)) return LocalDnsAction.Blocked
        }
        return LocalDnsAction.None
    }

    val isEmpty: Boolean get() =
        exactBlocks.isEmpty() && subtreeBlocks.isEmpty() && exactOverrides.isEmpty() && subtreeOverrides.isEmpty()

    /** Публичные снапшоты для мержа с курируемыми списками (live-push). */
    fun exactBlocksSnapshot(): Set<String> = exactBlocks.toSet()
    fun subtreeBlocksSnapshot(): Set<String> = subtreeBlocks.toSet()
    fun exactOverridesSnapshot(): Map<String, String> = exactOverrides.toMap()
    fun subtreeOverridesSnapshot(): Map<String, String> = subtreeOverrides.toMap()

    companion object {
        fun normalize(raw: String): String? {
            var d = raw.trim().lowercase()
            while (d.endsWith(".")) d = d.dropLast(1)
            if (d.isEmpty() || d == ".") return null
            if (!d.all { it.isLetterOrDigit() || it == '-' || it == '_' || it == '.' }) return null
            return d
        }

        private fun cleanOverrides(raw: Map<String, String>): Map<String, String> {
            val out = mutableMapOf<String, String>()
            for ((k, v) in raw) {
                val d = normalize(k) ?: continue
                if (d.isEmpty() || DnsWire.ipv4Bytes(v) == null) continue
                out[d] = v
            }
            return out
        }

        fun isValidDomain(s: String): Boolean {
            val d = normalize(s) ?: return false
            if (d.isEmpty()) return false
            val labels = d.split(".")
            if (labels.size < 2) return false
            for ((i, l) in labels.withIndex()) {
                if (l.length !in 1..63) return false
                if (!l.all { it.isLetterOrDigit() || it == '-' }) return false
                if (i == labels.size - 1 && (l.length < 2 || !l.all { it.isLetter() })) return false
            }
            return true
        }
    }
}
