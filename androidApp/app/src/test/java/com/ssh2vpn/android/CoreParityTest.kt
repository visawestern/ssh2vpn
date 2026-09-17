package com.ssh2vpn.android

import com.ssh2vpn.android.core.CountryCentroids
import com.ssh2vpn.android.core.DnsCache
import com.ssh2vpn.android.core.DnsRule
import com.ssh2vpn.android.core.DnsRuleKind
import com.ssh2vpn.android.core.DnsWire
import com.ssh2vpn.android.core.EgressTest
import com.ssh2vpn.android.core.EgressVerdict
import com.ssh2vpn.android.core.FakeTcpFactory
import com.ssh2vpn.android.core.HostsParser
import com.ssh2vpn.android.core.LocalDnsFilter
import com.ssh2vpn.android.core.MapProjection
import com.ssh2vpn.android.core.OfflineGeoIP
import com.ssh2vpn.android.core.SeqIsn
import com.ssh2vpn.android.core.TcpParser
import com.ssh2vpn.android.core.TcpRelayStateMachine
import com.ssh2vpn.android.core.buildSyn
import com.ssh2vpn.android.core.parseReplyTcp
import com.ssh2vpn.android.data.ConsoleLog
import com.ssh2vpn.android.data.QuotaLedger
import org.junit.Assert.*
import org.junit.Test

/** Порт iOS unit-тестов на чистое ядро + регрессия паритета (P-60). */
class CoreParityTest {

    // --- TCP relay ---
    @Test fun synAckHandshake() {
        val f = FakeTcpFactory()
        val m = TcpRelayStateMachine(f, SeqIsn(5000))
        val r1 = m.handle(buildSyn("10.8.0.5", 1234, "93.184.216.34", 80, 1000))
        assertEquals(1, r1.size)
        val s1 = parseReplyTcp(r1[0])
        assertTrue(s1.isSyn && s1.isAck)
        assertEquals(1001L, s1.ack)
        assertEquals(0, m.handle(buildSyn("10.8.0.5", 1234, "93.184.216.34", 80, 1001, s1.seq + 1, TcpParser.ACK, ByteArray(0))).size)
    }

    @Test fun dataForwardAndAck() {
        val f = FakeTcpFactory()
        val m = TcpRelayStateMachine(f, SeqIsn(77))
        val s1 = parseReplyTcp(m.handle(buildSyn("10.0.0.2", 4000, "1.1.1.1", 443, 100))[0])
        m.handle(buildSyn("10.0.0.2", 4000, "1.1.1.1", 443, 101, s1.seq + 1, TcpParser.ACK, ByteArray(0)))
        val r = m.handle(buildSyn("10.0.0.2", 4000, "1.1.1.1", 443, 101, s1.seq + 1, TcpParser.ACK, "hello".toByteArray()))
        assertEquals(5, f.sentBytes())
        assertEquals(106L, parseReplyTcp(r[0]).ack)
        assertEquals(5L, m.totalUpBytes)
    }

    @Test fun finAndStrayRst() {
        val f = FakeTcpFactory()
        val m = TcpRelayStateMachine(f, SeqIsn(9))
        val s1 = parseReplyTcp(m.handle(buildSyn("10.0.0.9", 80, "9.9.9.9", 53, 7))[0])
        m.handle(buildSyn("10.0.0.9", 80, "9.9.9.9", 53, 8, s1.seq + 1, TcpParser.ACK, ByteArray(0)))
        val fin = m.handle(buildSyn("10.0.0.9", 80, "9.9.9.9", 53, 8, s1.seq + 1, TcpParser.FIN or TcpParser.ACK, ByteArray(0)))
        assertEquals(9L, parseReplyTcp(fin[0]).ack)
        val stray = m.handle(buildSyn("10.0.0.9", 9999, "9.9.9.9", 53, 42, 0, TcpParser.ACK, "x".toByteArray(Charsets.UTF_8)))
        assertTrue(parseReplyTcp(stray[0]).isRst)
    }

    // --- DNS filter ---
    @Test fun dnsFilterPrecedence() {
        val f = LocalDnsFilter(listOf(
            DnsRule("ads.example.com", DnsRuleKind.BLOCK, "", true),
            DnsRule("my.local", DnsRuleKind.OVERRIDE, "10.0.0.5", false)
        ))
        assertEquals(com.ssh2vpn.android.core.LocalDnsAction.Blocked, f.actionFor("sub.ads.example.com"))
        assertEquals(com.ssh2vpn.android.core.LocalDnsAction.Override("10.0.0.5"), f.actionFor("my.local"))
        assertEquals(com.ssh2vpn.android.core.LocalDnsAction.None, f.actionFor("sub.my.local"))
        assertTrue(LocalDnsFilter.isValidDomain("example.com"))
        assertFalse(LocalDnsFilter.isValidDomain("bad..domain"))
    }

    @Test fun dnsWireAndCache() {
        fun q(name: String, id: Int): ByteArray {
            val out = mutableListOf<Byte>()
            out.add((id ushr 8).toByte()); out.add((id and 0xFF).toByte())
            out.addAll(listOf(0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00))
            name.split(".").forEach { l -> out.add(l.length.toByte()); l.forEach { out.add(it.code.toByte()) } }
            out.add(0); out.addAll(listOf(0x00, 0x01, 0x00, 0x01))
            return out.toByteArray()
        }
        val query = q("example.com", 0x1234)
        assertEquals("example.com", DnsWire.questionName(query))
        assertEquals(1, DnsWire.questionType(query))
        assertNotNull(DnsWire.aRecordReply(query, byteArrayOf(0, 0, 0, 0)))
        val cache = DnsCache()
        assertNull(cache.answerFor(query))
        val resp = query.toMutableList().apply {
            this[2] = 0x81.toByte(); this[3] = 0x80.toByte(); this[7] = 1
            addAll(listOf(0xC0.toByte(), 0x0C.toByte(), 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3C, 0x00, 0x04, 93.toByte(), 184.toByte(), 216.toByte(), 34.toByte()))
        }.toByteArray()
        cache.store(query, resp)
        val hit = reqNotNull(cache.answerFor(query))
        assertEquals(resp.size, hit.size)
        val q2 = q("example.com", 0x5678)
        assertEquals(0x56.toByte(), reqNotNull(cache.answerFor(q2))[0])
    }

    @Test fun hostsParser() {
        val p = HostsParser.parse("# c\n0.0.0.0 ads.example.com\n1.2.3.4 my.local\n||tracker.io^\nplain.org\n")
        assertTrue("ads.example.com" in p.blocked)
        assertTrue("tracker.io" in p.blocked)
        assertTrue("plain.org" in p.blocked)
        assertEquals("1.2.3.4", p.overrides["my.local"])
    }

    // --- Quota ---
    @Test fun quotaLedger() {
        val t0 = 1_700_000_000_000L
        val g = QuotaLedger().withInitialGrant(t0)
        assertEquals(3600L, g.remainingSec(t0))
        assertTrue(g.allowsConnection(t0))
        assertFalse(QuotaLedger().allowsConnection(t0))
        // Первый rewarded сразу после гранта разрешён (кулдауна ещё нет).
        assertNotNull(g.creditingAdView(t0))
        assertNull(QuotaLedger().withUnlimited().creditingAdView(t0))
    }

    @Test fun quotaAdFlow() {
        val t0 = 1_700_000_000_000L
        val g = QuotaLedger().withInitialGrant(t0)
        val c1 = reqNotNull(g.creditingAdView(t0))
        assertEquals(3600L + 3 * 3600L, c1.remainingSec(t0))
        assertNull(c1.creditingAdView(t0 + 1000)) // кулдаун
        val c2 = reqNotNull(c1.creditingAdView(t0 + 3600_000 + 1000))
        assertTrue(c2.remainingSec(t0 + 3600_000) <= 12 * 3600L) // cap
        assertTrue(QuotaLedger().withUnlimited().allowsConnection(t0 + 10L * 365 * 24 * 3600 * 1000))
        assertFalse(QuotaLedger().withUnlimited().removingUnlimited().allowsConnection(t0))
    }

    // --- Geo / map ---
    @Test fun centroidsAndProjection() {
        val de = reqNotNull(CountryCentroids.coordinate("DE"))
        assertEquals(51.17, de.first, 0.01)
        val (x, y) = MapProjection.viewPoint(de.second, de.first, 1920.0, 954.0, "DE")
        assertTrue(x in 700.0..950.0 && y in 100.0..300.0)
        // Синтетический GEO1-блоб: 1.2.3.0/24 -> US.
        val blob = geoBlob(mapOf((0x01020300L to 24) to 0), listOf("US"))
        assertTrue(OfflineGeoIP.load(blob))
        assertEquals("US", OfflineGeoIP.countryCode("1.2.3.4"))
        assertEquals(null, OfflineGeoIP.countryCode("9.9.9.9"))
        assertEquals("🇩🇪", OfflineGeoIP.flagEmoji("de"))
        assertTrue(OfflineGeoIP.isLocalOrPrivate("192.168.1.1"))
        assertFalse(OfflineGeoIP.isLocalOrPrivate("8.8.8.8"))
    }

    @Test fun egressVerdict() {
        assertTrue(EgressTest.evaluate("1.2.3.4", "1.2.3.4") is EgressVerdict.ViaServer)
        val b = EgressTest.evaluate("1.2.3.4", "5.6.7.8")
        assertTrue(b is EgressVerdict.Bypass && (b as EgressVerdict.Bypass).observed == "5.6.7.8")
        assertTrue(EgressTest.evaluate(null, "1.1.1.1") is EgressVerdict.UnknownExpected)
    }

    @Test fun sanitizeKeepsFlags() {
        val s = ConsoleLog.sanitize("password: hunter2 hasPassword=true key=AAAA")
        assertFalse("hunter2" in s)
        assertTrue("hasPassword=true" in s)
        val pem = ConsoleLog.sanitize("-----BEGIN OPENSSH PRIVATE KEY-----\nABC\n-----END OPENSSH PRIVATE KEY-----")
        assertFalse("ABC" in pem)
    }

    private fun geoBlob(v4: Map<Pair<Long, Int>, Int>, countries: List<String>): ByteArray {
        val out = mutableListOf<Byte>()
        out.addAll(listOf(0x47, 0x45, 0x4F, 0x31))
        fun u32(v: Long) {
            out.add(((v shr 24) and 0xFF).toByte()); out.add(((v shr 16) and 0xFF).toByte())
            out.add(((v shr 8) and 0xFF).toByte()); out.add((v and 0xFF).toByte())
        }
        u32(v4.size.toLong())
        for ((np, ci) in v4) {
            u32(np.first); out.add(np.second.toByte())
            out.add(((ci shr 8) and 0xFF).toByte()); out.add((ci and 0xFF).toByte())
        }
        u32(0) // v6 count
        out.add(0); out.add(countries.size.toByte())
        for (c in countries) { out.add(c[0].code.toByte()); out.add(c[1].code.toByte()) }
        return out.toByteArray()
    }

    private fun reqNotNull(v: ByteArray?): ByteArray {
        assertNotNull(v)
        return v!!
    }

    private fun <T> reqNotNull(v: T?): T {
        assertNotNull(v)
        return v!!
    }
}
