package com.ssh2vpn.android.data

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.ssh2vpn.android.core.DnsListCatalog
import com.ssh2vpn.android.core.LocalDnsFilter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

private val Context.dnsListsMeta by preferencesDataStore("dns_lists")

@Serializable
data class SubscribedList(
    val id: String,
    val updatedAt: Long = 0,
    val domains: Int = 0,
    val failed: Boolean = false
)

/**
 * Курируемые DNS-списки — порт DNSListStore: подписки, скачивание hosts-файлов,
 * парсинг, мерж поверх ручных правил. Обновление — вручную/при коннекте, если
 * старше 7 дней (без WorkManager — дешевле и прозрачнее).
 */
class DnsListStore(private val ctx: Context) {
    private val kSubs = stringPreferencesKey("subscribed")
    private val kDataPrefix = "dnslist.data."
    private val json = Json { ignoreUnknownKeys = true }
    private val files = ctx.getFilesDir()

    suspend fun subscribed(): List<SubscribedList> {
        val raw = ctx.dnsListsMeta.data.map { it[kSubs] }.first() ?: return emptyList()
        return try { json.decodeFromString(raw) } catch (_: Exception) { emptyList() }
    }

    private suspend fun saveSubs(list: List<SubscribedList>) {
        ctx.dnsListsMeta.edit { it.set(kSubs, json.encodeToString(list)) }
    }

    suspend fun subscribe(id: String) {
        if (DnsListCatalog.source(id) == null) return
        val cur = subscribed().toMutableList()
        if (cur.none { it.id == id }) {
            cur.add(SubscribedList(id))
            saveSubs(cur)
        }
        refresh(id)
    }

    suspend fun unsubscribe(id: String) {
        saveSubs(subscribed().filter { it.id != id })
        try { java.io.File(files, kDataPrefix + id).delete() } catch (_: Exception) {}
    }

    /** Скачать и распарсить один список. Возвращает число доменов или null при ошибке. */
    suspend fun refresh(id: String): Int? = withContext(Dispatchers.IO) {
        val src = DnsListCatalog.source(id) ?: return@withContext null
        try {
            val url = java.net.URL(src.url)
            val conn = url.openConnection() as java.net.HttpURLConnection
            conn.connectTimeout = 20_000; conn.readTimeout = 30_000
            conn.setRequestProperty("User-Agent", "SSH2VPN-Android/1.0")
            if (conn.responseCode !in 200..299) throw java.io.IOException("HTTP ${conn.responseCode}")
            val text = conn.inputStream.bufferedReader().use { it.readText() }
            if (text.length > 20_000_000) throw java.io.IOException("list too large")
            val parsed = com.ssh2vpn.android.core.HostsParser.parse(text)
            val domains = (parsed.blocked + parsed.overrides.keys).toSortedSet()
            java.io.File(files, kDataPrefix + id).writeText(domains.joinToString("\n"))
            val cur = subscribed().map { if (it.id == id) it.copy(updatedAt = System.currentTimeMillis(), domains = domains.size, failed = false) else it }
            saveSubs(cur)
            ConsoleLog.log("ok", "DNSLIST", "$id: ${domains.size} доменов")
            domains.size
        } catch (e: Exception) {
            val cur = subscribed().map { if (it.id == id) it.copy(failed = true) else it }
            try { saveSubs(cur) } catch (_: Exception) {}
            ConsoleLog.log("warn", "DNSLIST", "$id: не обновлён (${e.message})")
            null
        }
    }

    suspend fun refreshStale(maxAgeMs: Long = 7L * 24 * 3600 * 1000) {
        val now = System.currentTimeMillis()
        for (s in subscribed()) {
            if (now - s.updatedAt > maxAgeMs) refresh(s.id)
        }
    }

    /** Все подписанные домены → subtree-блоки поверх ручных правил. */
    suspend fun curatedBlocks(): Set<String> = withContext(Dispatchers.IO) {
        val out = mutableSetOf<String>()
        for (s in subscribed()) {
            try {
                val f = java.io.File(files, kDataPrefix + s.id)
                if (f.exists()) f.forEachLine { l ->
                    val d = LocalDnsFilter.normalize(l)
                    if (!d.isNullOrEmpty()) out.add(d)
                }
            } catch (_: Exception) {}
        }
        out
    }

    suspend fun totalDomains(): Int = subscribed().sumOf { it.domains }
}
