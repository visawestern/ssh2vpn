package com.ssh2vpn.android.core

/**
 * Офлайн GeoIP — порт OfflineGeoIP.swift. Таблица — ТОТ ЖЕ файл
 * `assets/geoip.dat` (магия GEO1, longest-prefix-match). Адрес сервера
 * никуда не уходит с устройства.
 */
object OfflineGeoIP {
    private data class V6Key(val hi: Long, val lo: Long, val plen: Int)
    private class Tables(val v4: Map<Long, Int>, val v6: Map<V6Key, Int>, val countries: List<String>) {
        fun lookupV4(ip: Long): String? {
            for (plen in 32 downTo 0) {
                val mask = if (plen == 0) 0L else (0xFFFFFFFFL shl (32 - plen)) and 0xFFFFFFFFL
                val key = ((ip and mask) shl 6) or plen.toLong()
                val ci = v4[key] ?: continue
                return countries.getOrNull(ci)
            }
            return null
        }
        fun lookupV6(hi: Long, lo: Long): String? {
            for (plen in 128 downTo 0) {
                val (mhi, mlo) = mask128(plen)
                val ci = v6[V6Key(hi and mhi, lo and mlo, plen)] ?: continue
                return countries.getOrNull(ci)
            }
            return null
        }
        private fun mask128(plen: Int): Pair<Long, Long> = when {
            plen <= 0 -> 0L to 0L
            plen >= 128 -> -1L to -1L
            plen >= 65 -> -1L to (-1L shl (128 - plen))
            else -> (-1L shl (64 - plen)) to 0L
        }
    }

    @Volatile private var tables: Tables? = null
    @Volatile private var loadTried = false

    fun load(bytes: ByteArray): Boolean {
        if (loadTried) return tables != null
        loadTried = true
        tables = parse(bytes)
        return tables != null
    }

    val loadedPrefixCount: Int? get() = tables?.let { it.v4.size + it.v6.size }

    fun countryCode(ipString: String): String? {
        val t = tables ?: return null
        val s = ipString.trim().removeSurrounding("[", "]").toString()
        parseIPv4(s)?.let { return t.lookupV4(it) }
        parseIPv6(s)?.let { return t.lookupV6(it.first, it.second) }
        return null
    }

    /** Хост: литералы — сразу, имена — через системный резолвер (без гео-сервисов). */
    fun countryCodeForHost(host: String): String? {
        val t = host.trim().removeSurrounding("[", "]").toString()
        if (t.isEmpty()) return null
        if (parseIPv4(t) != null || parseIPv6(t) != null) return countryCode(t)
        return try {
            val addrs = java.net.InetAddress.getAllByName(t)
            addrs.firstNotNullOfOrNull { countryCode(it.hostAddress ?: "") }
        } catch (_: Exception) { null }
    }

    fun isIPAddress(s: String): Boolean {
        val t = s.trim().removeSurrounding("[", "]").toString()
        return parseIPv4(t) != null || parseIPv6(t) != null
    }

    internal fun parseIPv4(s: String): Long? {
        val parts = s.split(".")
        if (parts.size != 4) return null
        var out = 0L
        for (p in parts) {
            if (p.isEmpty() || p.length > 3 || !p.all { it.isDigit() }) return null
            val b = p.toLongOrNull() ?: return null
            if (b > 255) return null
            if (p.length > 1 && p.startsWith("0")) return null
            out = (out shl 8) or b
        }
        return out
    }

    internal fun parseIPv6(s: String): Pair<Long, Long>? {
        if (s.isEmpty() || ':' !in s) return null
        var addr = s
        var tail: Long? = null
        val lastColon = s.lastIndexOf(':')
        val after = s.substring(lastColon + 1)
        if ('.' in after) {
            tail = parseIPv4(after) ?: return null
            addr = s.substring(0, lastColon) + ":0:0"
            if (addr.startsWith(":") && !addr.startsWith("::")) return null
        }
        val halves = addr.split("::")
        if (halves.size > 2) return null
        fun groups(part: String): List<Int>? {
            if (part.isEmpty()) return emptyList()
            return part.split(":").map {
                if (it.isEmpty() || it.length > 4) return null
                it.toIntOrNull(16) ?: return null
            }
        }
        val left = groups(halves[0]) ?: return null
        val full: List<Int>
        if (halves.size == 2) {
            val right = groups(halves[1]) ?: return null
            val missing = 8 - left.size - right.size
            if (missing < 0) return null
            full = left + List(missing) { 0 } + right
        } else full = left
        if (full.size != 8) return null
        val g = full.toMutableList()
        tail?.let { g[6] = ((it shr 16) and 0xFFFF).toInt(); g[7] = (it and 0xFFFF).toInt() }
        var hi = 0L; var lo = 0L
        for (i in 0..3) hi = (hi shl 16) or (g[i].toLong() and 0xFFFF)
        for (i in 4..7) lo = (lo shl 16) or (g[i].toLong() and 0xFFFF)
        return hi to lo
    }

    private fun parse(bytes: ByteArray): Tables? {
        if (bytes.size < 4 || bytes[0] != 0x47.toByte() || bytes[1] != 0x45.toByte() ||
            bytes[2] != 0x4F.toByte() || bytes[3] != 0x31.toByte()
        ) return null
        var off = 4
        fun u32(): Long? {
            if (off + 4 > bytes.size) return null
            val v = ((bytes[off].toLong() and 0xFF) shl 24) or ((bytes[off + 1].toLong() and 0xFF) shl 16) or
                ((bytes[off + 2].toLong() and 0xFF) shl 8) or (bytes[off + 3].toLong() and 0xFF)
            off += 4; return v
        }
        fun u16(): Int? {
            if (off + 2 > bytes.size) return null
            val v = ((bytes[off].toInt() and 0xFF) shl 8) or (bytes[off + 1].toInt() and 0xFF)
            off += 2; return v
        }
        fun u8(): Int? {
            if (off >= bytes.size) return null
            return (bytes[off++].toInt() and 0xFF)
        }
        fun u64(): Long? {
            if (off + 8 > bytes.size) return null
            var v = 0L
            for (i in 0..7) v = (v shl 8) or (bytes[off + i].toLong() and 0xFF)
            off += 8; return v
        }
        val c4 = u32() ?: return null
        if (c4 >= 2_000_000) return null
        val v4 = HashMap<Long, Int>(c4.toInt())
        repeat(c4.toInt()) {
            val net = u32() ?: return null
            val plen = u8() ?: return null
            val ci = u16() ?: return null
            if (plen > 32) return null
            v4[(net shl 6) or plen.toLong()] = ci
        }
        val c6 = u32() ?: return null
        if (c6 >= 1_000_000) return null
        val v6 = HashMap<V6Key, Int>(c6.toInt())
        repeat(c6.toInt()) {
            val hi = u64() ?: return null
            val lo = u64() ?: return null
            val plen = u8() ?: return null
            val ci = u16() ?: return null
            if (plen > 128) return null
            v6[V6Key(hi, lo, plen)] = ci
        }
        val cc = u16() ?: return null
        if (cc >= 1000) return null
        val countries = ArrayList<String>(cc)
        repeat(cc) {
            if (off + 2 > bytes.size) return null
            countries.add(String(byteArrayOf(bytes[off], bytes[off + 1]), Charsets.US_ASCII))
            off += 2
        }
        return Tables(v4, v6, countries)
    }

    fun flagEmoji(countryCode: String): String {
        val code = countryCode.uppercase()
        if (code.length != 2) return "🌐"
        val sb = StringBuilder()
        for (c in code) {
            val scalar = 127397 + c.code
            sb.appendCodePoint(scalar)
        }
        val s = sb.toString()
        return s.ifEmpty { "🌐" }
    }

    fun isLocalOrPrivate(host: String): Boolean {
        val h = host.lowercase().trim()
        if (h == "localhost" || h == "127.0.0.1" || h == "::1") return true
        if (h.startsWith("192.168.") || h.startsWith("10.")) return true
        if (h.startsWith("172.")) {
            val second = h.removePrefix("172.").substringBefore(".").toIntOrNull()
            if (second != null && second in 16..31) return true
        }
        return false
    }
}
