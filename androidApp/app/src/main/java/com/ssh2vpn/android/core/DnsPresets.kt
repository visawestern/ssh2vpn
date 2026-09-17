package com.ssh2vpn.android.core

/** Каталог публичных DNS-пресетов — порт DNSPresets.swift 1-в-1 (те же 19 записей). */
data class DnsPreset(
    val id: String, val name: String,
    val primary: String, val secondary: String,
    val chips: List<String>
) {
    fun matches(primary: String, secondary: String): Boolean =
        this.primary == primary.trim() && this.secondary == secondary.trim()
}

object DnsPresets {
    val all: List<DnsPreset> = listOf(
        DnsPreset("cloudflare", "Cloudflare", "1.1.1.1", "1.0.0.1", listOf("noFilter", "privacy")),
        DnsPreset("google", "Google Public DNS", "8.8.8.8", "8.8.4.4", listOf("noFilter")),
        DnsPreset("adguard-unfiltered", "AdGuard Unfiltered", "94.140.14.140", "94.140.14.141", listOf("noFilter", "privacy")),
        DnsPreset("yandex", "Yandex DNS", "77.88.8.8", "77.88.8.1", listOf("noFilter")),
        DnsPreset("dns-watch", "DNS.Watch", "84.200.69.80", "84.200.70.40", listOf("noFilter", "privacy")),
        DnsPreset("verisign", "Verisign", "64.6.64.6", "64.6.65.6", listOf("noFilter")),
        DnsPreset("level3", "Level3 / Lumen", "4.2.2.1", "4.2.2.2", listOf("noFilter")),
        DnsPreset("quad9", "Quad9", "9.9.9.9", "149.112.112.112", listOf("malware", "phishing")),
        DnsPreset("cloudflare-malware", "Cloudflare Security", "1.1.1.2", "1.0.0.2", listOf("malware", "phishing")),
        DnsPreset("dns0-zero", "dns0.eu ZERO", "193.110.81.0", "185.253.5.0", listOf("malware", "phishing")),
        DnsPreset("opendns", "OpenDNS (Cisco)", "208.67.222.222", "208.67.220.220", listOf("phishing")),
        DnsPreset("comodo", "Comodo Secure DNS", "8.26.56.26", "8.20.247.20", listOf("malware", "phishing")),
        DnsPreset("adguard", "AdGuard DNS", "94.140.14.14", "94.140.15.15", listOf("ads", "trackers", "malware")),
        DnsPreset("cloudflare-family", "Cloudflare Family", "1.1.1.3", "1.0.0.3", listOf("adult", "malware")),
        DnsPreset("adguard-family", "AdGuard Family", "94.140.14.15", "94.140.15.16", listOf("adult", "ads", "trackers", "malware", "safeSearch")),
        DnsPreset("cleanbrowsing-family", "CleanBrowsing Family", "185.228.168.168", "185.228.169.168", listOf("adult", "malware", "phishing", "safeSearch")),
        DnsPreset("cleanbrowsing-adult", "CleanBrowsing Adult", "185.228.168.10", "185.228.169.11", listOf("adult")),
        DnsPreset("opendns-familyshield", "OpenDNS FamilyShield", "208.67.222.123", "208.67.220.123", listOf("adult", "phishing")),
        DnsPreset("yandex-family", "Yandex Family", "77.88.8.88", "77.88.8.2", listOf("adult"))
    )
}
