package com.ssh2vpn.android.core

/**
 * TTL-кэш DNS-ответов — порт DNSCache (Swift) 1-в-1:
 * maxTTL 300с, negative 60с, servfail 10с, minStore 5с, capacity 2048.
 */
class DnsCache(private val capacity: Int = 2048) {
    companion object {
        const val MAX_TTL_SEC = 300L
        const val MAX_NEGATIVE_TTL = 60L
        const val MAX_SERVFAIL_TTL = 10L
        const val MIN_STORE_TTL = 5L

        fun keyFor(query: ByteArray): String? {
            val name = DnsWire.questionName(query) ?: return null
            if (query.size < 17) return null
            var i = 12
            while (i < query.size && query[i].toInt() != 0) i += (query[i].toInt() and 0xFF) + 1
            if (i + 5 > query.size || query[i].toInt() != 0) return null
            val tail = query.copyOfRange(i + 1, i + 5).joinToString("") { "%02x".format(it) }
            return "$name:$tail"
        }

        internal fun cacheTtlOf(response: ByteArray): Long? {
            if (response.size < 12) return null
            val rcode = response[3].toInt() and 0x0F
            val qd = u16(response, 4); val an = u16(response, 6); val ns = u16(response, 8)
            var i = 12
            repeat(qd) {
                if (i >= response.size) return null
                while (i < response.size && response[i].toInt() != 0) i += (response[i].toInt() and 0xFF) + 1
                i += 5
            }
            val ans = scanRecords(response, i, an) ?: return null
            ans.positive?.let { return minOf(it, MAX_TTL_SEC) }
            val auth = scanRecords(response, ans.next, ns) ?: return null
            val soa = auth.soa ?: ans.soa ?: return null
            if (soa <= 0) return null
            return when {
                rcode == 3 -> minOf(soa, MAX_NEGATIVE_TTL)
                rcode == 2 -> minOf(soa, MAX_SERVFAIL_TTL)
                rcode == 0 && an == 0 -> minOf(soa, MAX_NEGATIVE_TTL)
                else -> null
            }
        }

        private data class Scan(val positive: Long?, val soa: Long?, val next: Int)

        private fun scanRecords(r: ByteArray, from: Int, count: Int): Scan? {
            var i = from
            var pos: Long? = null; var soa: Long? = null
            repeat(count) {
                if (i >= r.size) return null
                if (r[i].toInt() and 0xC0 == 0xC0) i += 2
                else { while (i < r.size && r[i].toInt() != 0) i += (r[i].toInt() and 0xFF) + 1; i++ }
                if (i + 10 > r.size) return null
                val type = u16(r, i)
                val ttl = u32(r, i + 4)
                val rdlen = u16(r, i + 8)
                i += 10 + rdlen
                if (pos == null && (type == 1 || type == 28)) pos = ttl
                if (soa == null && type == 6) soa = ttl
            }
            return Scan(pos, soa, i)
        }

        private fun u16(b: ByteArray, i: Int) = (((b[i].toInt() and 0xFF) shl 8) or (b[i + 1].toInt() and 0xFF))
        private fun u32(b: ByteArray, i: Int): Long =
            (((b[i].toLong() and 0xFF) shl 24) or ((b[i + 1].toLong() and 0xFF) shl 16) or
                ((b[i + 2].toLong() and 0xFF) shl 8) or (b[i + 3].toLong() and 0xFF))

        internal fun rewriteId(payload: ByteArray, query: ByteArray): ByteArray {
            if (payload.size < 2 || query.size < 2) return payload
            val out = payload.copyOf()
            out[0] = query[0]; out[1] = query[1]
            return out
        }
    }

    private data class Entry(val payload: ByteArray, val expiresAt: Long)
    private val entries = LinkedHashMap<String, Entry>()
    val size: Int get() = synchronized(this) { entries.size }

    fun answerFor(query: ByteArray): ByteArray? = synchronized(this) {
        val k = keyFor(query) ?: return null
        val e = entries[k] ?: return null
        if (e.expiresAt <= System.currentTimeMillis()) { entries.remove(k); return null }
        rewriteId(e.payload, query)
    }

    /** Миллисекунд до протухания хита (для early-refresh), null при промахе. */
    fun remainingMs(query: ByteArray): Long? = synchronized(this) {
        val k = keyFor(query) ?: return null
        val e = entries[k] ?: return null
        val left = e.expiresAt - System.currentTimeMillis()
        if (left <= 0) { entries.remove(k); return null }
        left
    }

    fun store(query: ByteArray, response: ByteArray) = synchronized(this) {
        val k = keyFor(query) ?: return
        val ttl = cacheTtlOf(response) ?: return
        if (ttl < MIN_STORE_TTL) return
        evictExpired()
        if (entries.size >= maxOf(16, capacity)) {
            entries.minByOrNull { it.value.expiresAt }?.key?.let { entries.remove(it) }
        }
        entries[k] = Entry(response, System.currentTimeMillis() + minOf(ttl, MAX_TTL_SEC) * 1000)
    }

    private fun evictExpired() {
        val t = System.currentTimeMillis()
        entries.entries.removeIf { it.value.expiresAt <= t }
    }
}
