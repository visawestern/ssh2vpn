package com.ssh2vpn.android.vpn

import com.ssh2vpn.android.core.DnsCache
import com.ssh2vpn.android.core.DnsWire
import com.ssh2vpn.android.core.LocalDnsAction
import com.ssh2vpn.android.core.LocalDnsFilter
import com.ssh2vpn.android.data.ConsoleLog
import com.ssh2vpn.android.ssh.SshConnectionPool
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * DNS relay — зеркало iOS-расширения:
 * 1) локальные правила (block -> 0.0.0.0, override -> свой IP) — ДО любого upstream;
 * 2) TTL-кэш (cap 300с);
 * 3) upstream через ОТДЕЛЬНЫЙ direct-tcpip канал к резолверу по TCP
 *    (DNS-over-TCP фрейминг: 2-байтовый length-prefix). Никакого UDP наружу.
 */
class DnsRelay(
    private val pool: SshConnectionPool,
    private var filter: LocalDnsFilter = LocalDnsFilter(),
    private var upstreams: List<String> = listOf("8.8.8.8", "1.1.1.1")
) {
    private val cache = DnsCache()
    private val refreshThread = java.util.concurrent.Executors.newSingleThreadExecutor { r ->
        Thread(r, "dns-refresh").apply { isDaemon = true }
    }
    @Volatile var answeredLocal = 0L
    @Volatile var answeredCache = 0L
    @Volatile var answeredUpstream = 0L

    fun configure(filter: LocalDnsFilter, upstreams: List<String>) {
        this.filter = filter
        this.upstreams = upstreams.filter { it.isNotBlank() }.ifEmpty { listOf("8.8.8.8", "1.1.1.1") }
    }

    /** UDP-пейлоад DNS-запроса -> UDP-пейлоад ответа (null = дропнуть). */
    fun resolve(query: ByteArray, timeoutMs: Int = 5000, useCache: Boolean = true): ByteArray? {
        val name = DnsWire.questionName(query)
        val qtype = DnsWire.questionType(query)
        // 1) Локальные правила — только для A (остальным — REFUSED, как в iOS).
        if (name != null) {
            when (val a = filter.actionFor(name)) {
                is LocalDnsAction.Blocked -> {
                    answeredLocal++
                    ConsoleLog.log("info", "DNS", "block $name -> 0.0.0.0")
                    return if (qtype == 1) DnsWire.aRecordReply(query, byteArrayOf(0, 0, 0, 0))
                    else DnsWire.refusedReply(query)
                }
                is LocalDnsAction.Override -> {
                    answeredLocal++
                    val ip = DnsWire.ipv4Bytes(a.ip) ?: return DnsWire.refusedReply(query)
                    ConsoleLog.log("info", "DNS", "override $name -> ${a.ip}")
                    return if (qtype == 1) DnsWire.aRecordReply(query, ip)
                    else DnsWire.refusedReply(query)
                }
                else -> {}
            }
        }
        // 2) Кэш + early-refresh почти просроченного (следующий лукaп не ждёт).
        if (useCache) {
            cache.answerFor(query)?.let { hit ->
                answeredCache++
                if ((cache.remainingMs(query) ?: Long.MAX_VALUE) < 30_000) {
                    refreshThread.execute { resolve(query, timeoutMs, false) }
                }
                return hit
            }
        }
        // 3) Upstream по TCP через direct-tcpip.
        for (up in upstreams) {
            val resp = queryOverTcp(up, 53, query, timeoutMs)
            if (resp != null) {
                cache.store(query, resp)
                answeredUpstream++
                return resp
            }
        }
        return null
    }

    private fun queryOverTcp(host: String, port: Int, query: ByteArray, timeoutMs: Int): ByteArray? {
        val framed = ByteBuffer.allocate(2 + query.size).order(ByteOrder.BIG_ENDIAN)
            .putShort(query.size.toShort()).put(query).array()
        val got = java.util.concurrent.LinkedBlockingQueue<ByteArray>()
        val closed = java.util.concurrent.LinkedBlockingQueue<Boolean>()
        // Фиктивный флоу: upstream задаём явно (как openTo в iOS-пуле).
        val ch = pool.openTo(
            flow = dummyFlow(), targetHost = host, targetPort = port,
            onData = { got.offer(it) }, onClosed = { closed.offer(true) }
        )
        return try {
            ch.send(framed)
            val buf = ByteArrayOutputStream()
            val t0 = System.currentTimeMillis()
            var want = -1
            while (System.currentTimeMillis() - t0 < timeoutMs) {
                val chunk = got.poll(200, java.util.concurrent.TimeUnit.MILLISECONDS)
                if (chunk != null) buf.write(chunk)
                val b = buf.toByteArray()
                if (want < 0 && b.size >= 2) {
                    want = (((b[0].toInt() and 0xFF) shl 8) or (b[1].toInt() and 0xFF))
                }
                if (want >= 0 && b.size >= 2 + want) {
                    return b.copyOfRange(2, 2 + want)
                }
                if (closed.peek() != null && want < 0) break
            }
            null
        } finally {
            runCatching { ch.close() }
        }
    }

    private fun dummyFlow(): com.ssh2vpn.android.core.RelayFlow =
        com.ssh2vpn.android.core.RelayFlow(byteArrayOf(10, 8, 0, 2), 0, byteArrayOf(10, 8, 0, 1), 53)
}
