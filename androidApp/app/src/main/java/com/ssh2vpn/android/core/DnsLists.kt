package com.ssh2vpn.android.core

/** Курируемый hosts-список — порт DNSListSource (URL те же, что в iOS). */
data class DnsListSource(
    val id: String, val name: String, val url: String,
    val category: String, val entryCount: Int
)

object DnsListCatalog {
    val all: List<DnsListSource> = listOf(
        DnsListSource("adaway", "AdAway Default", "https://adaway.org/hosts.txt", "general", 9500),
        DnsListSource("yoyo", "pgl.yoyo.org", "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=0&mimetype=plaintext", "ads", 3600),
        DnsListSource("stevenblack", "StevenBlack Unified", "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts", "general", 120000),
        DnsListSource("mvps", "MVPS Hosts", "https://winhelp2002.mvps.org/hosts.txt", "ads", 12000),
        DnsListSource("easyprivacy-nsfw-placeholder", "EasyList Tracker Sites", "https://raw.githubusercontent.com/lightswitch05/hosts/master/tracking-aggressive-extended/list.txt", "privacy", 13000),
        DnsListSource("someonewhocares", "Somebody Who Cares", "https://someonewhocares.org/hosts/hosts", "privacy", 14000),
        DnsListSource("urlhaus", "URLhaus Abuse.ch", "https://urlhaus.abuse.ch/downloads/hostfile/", "malware", 2000),
        DnsListSource("shadowwhocares-phishing", "Phishing Army", "https://phishing.army/download/phishing_army_blocklist_extended.txt", "malware", 40000),
        DnsListSource("ruadlist-500", "500 RU Ad Servers", "https://raw.githubusercontent.com/durak/stringer/master/hostlists/ruadlist-500.txt", "regional", 500),
        DnsListSource("disconnect-tracking", "Disconnect Tracking", "https://s3.amazonaws.com/lists.disconnect.me/simple_tracking.txt", "privacy", 2800),
        DnsListSource("disconnect-ads", "Disconnect Ads", "https://s3.amazonaws.com/lists.disconnect.me/simple_ad.txt", "ads", 2900)
    )
    fun source(id: String): DnsListSource? = all.firstOrNull { it.id == id }
}

/**
 * Парсер hosts-файлов — порт LocalDNSFilter(blocklistText:) + `||domain^`:
 * "example.com" / "0.0.0.0 example.com" (block) / "1.2.3.4 example.com"
 * (override) / "||example.com^", комментарии # и !. Семантика hosts = subtree.
 */
object HostsParser {
    data class Parsed(val blocked: Set<String>, val overrides: Map<String, String>)

    fun parse(text: String): Parsed {
        val blocked = mutableSetOf<String>()
        val overrides = mutableMapOf<String, String>()
        for (rawLine in text.lines()) {
            val line = rawLine.trim()
            if (line.isEmpty() || line.startsWith("#") || line.startsWith("!")) continue
            var domain: String? = null
            var ip: String? = null
            if (line.startsWith("||")) {
                val body = line.drop(2)
                domain = body.split("^", " ", "$").firstOrNull()
            } else {
                val parts = line.split(Regex("\\s+"))
                if (parts.size >= 2 && DnsWire.ipv4Bytes(parts[0]) != null) {
                    ip = parts[0]
                    domain = parts[1].substringBefore("#")
                } else if (parts.size == 1) {
                    domain = parts[0].substringBefore("#")
                }
            }
            val d = domain?.let { LocalDnsFilter.normalize(it) }
            if (d.isNullOrEmpty()) continue
            if (ip != null && ip != "0.0.0.0" && ip != "127.0.0.1") overrides[d] = ip
            else blocked.add(d)
        }
        return Parsed(blocked, overrides)
    }
}
