package com.ssh2vpn.android.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import com.ssh2vpn.android.MainActivity
import com.ssh2vpn.android.R
import com.ssh2vpn.android.core.ConnectionBreaker
import com.ssh2vpn.android.core.DnsRule
import com.ssh2vpn.android.core.DnsRuleKind
import com.ssh2vpn.android.core.EgressTest
import com.ssh2vpn.android.core.EgressVerdict
import com.ssh2vpn.android.core.IpTransport
import com.ssh2vpn.android.core.Ipv4Parser
import com.ssh2vpn.android.core.LocalDnsFilter
import com.ssh2vpn.android.core.RelayFlow
import com.ssh2vpn.android.core.SshStartError
import com.ssh2vpn.android.core.TcpRelayStateMachine
import com.ssh2vpn.android.core.UdpParser
import com.ssh2vpn.android.data.AppSettings
import com.ssh2vpn.android.data.ConsoleLog
import com.ssh2vpn.android.data.DnsListStore
import com.ssh2vpn.android.data.QuotaStore
import com.ssh2vpn.android.data.ServerStore
import com.ssh2vpn.android.data.SettingsStore
import com.ssh2vpn.android.ssh.SecureIsn
import com.ssh2vpn.android.ssh.SshConnectionPool
import com.ssh2vpn.android.ssh.SshCredentials
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.suspendCancellableCoroutine
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.NetworkInterface
import java.security.MessageDigest
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume
import kotlin.math.min

/** Живая DNS-конфигурация для running-туннеля (эквивалент dnsRulesSet без IPC). */
data class LiveDnsConfig(val filter: LocalDnsFilter, val upstreams: List<String>)

/**
 * Системный VPN-сервис — Android-аналог NEPacketTunnelProvider (iOS).
 * TUN -> IPv4 TCP relay -> SSH direct-tcpip -> штатный sshd.
 */
class SshVpnService : VpnService() {

    data class Stats(
        val upBytes: Long = 0, val downBytes: Long = 0,
        val flows: Int = 0, val channels: Int = 0, val poolConns: Int = 0,
        val udpDropped: Long = 0, val v6Dropped: Long = 0, val dnsUpstream: Long = 0,
        val packetsRead: Long = 0, val packetsWritten: Long = 0,
        val protoSplit: String = "", val egress: String = "", val stopReason: String = "none"
    )

    companion object {
        const val ACTION_START = "com.ssh2vpn.android.START"
        const val ACTION_STOP = "com.ssh2vpn.android.STOP"
        const val EXTRA_SERVER_ID = "server_id"

        private val _phase = MutableStateFlow("idle")
        val phase: StateFlow<String> = _phase
        private val _stats = MutableStateFlow(Stats())
        val stats: StateFlow<Stats> = _stats
        private val _lastError = MutableStateFlow<String?>(null)
        val lastError: StateFlow<String?> = _lastError
        private val _lastErrorCode = MutableStateFlow<String?>(null)
        val lastErrorCode: StateFlow<String?> = _lastErrorCode

        /** Живой пуш DNS-правил в running-туннель (dnsRulesSet без IPC). */
        val liveDns = MutableStateFlow<LiveDnsConfig?>(null)

        /** Рубильник шторма коннектов (10 подряд) — как ConnectionBreaker в iOS. */
        val breaker = ConnectionBreaker()

        fun startCmd(ctx: android.content.Context, serverId: String) {
            breaker.reset() // ручной коннект всегда перевооружает
            val i = Intent(ctx, SshVpnService::class.java).setAction(ACTION_START)
                .putExtra(EXTRA_SERVER_ID, serverId)
            if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i) else ctx.startService(i)
        }
        fun stopCmd(ctx: android.content.Context) {
            ctx.startService(Intent(ctx, SshVpnService::class.java).setAction(ACTION_STOP))
        }
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var tun: ParcelFileDescriptor? = null
    private var loopJob: Job? = null
    private var pool: SshConnectionPool? = null
    private var relay: TcpRelayStateMachine? = null
    private var dnsRelay: DnsRelay? = null
    private val toPhone = LinkedBlockingQueue<ByteArray>()
    @Volatile private var running = false
    private val cancelled = AtomicBoolean(false)
    private var udpDropped = 0L
    private var v6Dropped = 0L
    private var v4other = 0L
    private var nonIP = 0L
    private var packetsRead = 0L
    @Volatile private var lastReadAt = 0L
    private var stopReason = "none"
    private var egressVerdict: String = ""
    private var dnsJob: Job? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> { teardown("user stop", "user"); stopSelf(); return START_NOT_STICKY }
            ACTION_START -> {
                val id = intent.getStringExtra(EXTRA_SERVER_ID) ?: return START_NOT_STICKY
                if (breaker.tripped) {
                    _phase.value = "failed"
                    fail("Слишком много неудачных попыток подряд — авто-дозвон остановлен (защита сервера). Нажмите Connect вручную.", "breakerTripped")
                    stopSelf()
                    return START_NOT_STICKY
                }
                startForegroundCompat()
                scope.launch { bringUp(id) }
            }
        }
        return START_STICKY
    }

    private fun fail(msg: String, code: String?) {
        _lastError.value = msg
        _lastErrorCode.value = code
        persistLastError(msg)
    }

    private fun persistLastError(msg: String) {
        // Аналог TunnelLastError: переживает смерть процесса сервиса.
        try {
            getSharedPreferences("tunnel", MODE_PRIVATE).edit().putString("last_error", msg.take(512)).apply()
        } catch (_: Exception) {}
    }

    fun readPersistedError(): String? {
        return try { getSharedPreferences("tunnel", MODE_PRIVATE).getString("last_error", null) } catch (_: Exception) { null }
    }

    private fun clearPersistedError() {
        try { getSharedPreferences("tunnel", MODE_PRIVATE).edit().remove("last_error").apply() } catch (_: Exception) {}
    }

    private suspend fun bringUp(serverId: String) {
        if (running) return
        cancelled.set(false)
        _lastError.value = null
        _lastErrorCode.value = null
        egressVerdict = ""
        val quota = QuotaStore(this).load()
        if (!quota.allowsConnection()) {
            _phase.value = "failed"
            fail("Бесплатное время исчерпано. Посмотрите рекламу (+3ч) или купите Unlimited.", "quotaExhausted")
            breaker.recordFailure()
            stopSelf()
            return
        }
        val store = ServerStore(this)
        val all = store.loadAll()
        val prof = all.firstOrNull { it.id == serverId } ?: all.firstOrNull()
        if (prof == null) {
            _phase.value = "failed"; fail("Нет серверов. Добавьте сервер.", "noServers")
            stopSelf(); return
        }
        val settings = SettingsStore(this).load()
        val password = store.password(prof.id)
        val privKey = store.privateKey(prof.id)

        // --- TUN: подсеть без коллизий (порт TunnelSubnetPicker) ---
        _phase.value = "ssh"
        val net = pickSubnet()
        val builder = Builder()
            .setSession("SSH2VPN")
            .setMtu(1500)
            .addAddress(net.deviceAddress, 24)
            .addRoute("0.0.0.0", 0)
            .addRoute("::", 0)
            .addDnsServer(net.gatewayAddress)
            .setBlocking(false)
            .setMetered(false)
        if (!settings.killSwitch) builder.allowBypass()
        val pfd = try { builder.establish() } catch (e: Exception) {
            _phase.value = "failed"; fail("Не удалось создать VPN-интерфейс: ${e.message}", "tunFailed")
            breaker.recordFailure()
            stopSelf(); return
        }
        if (pfd == null || cancelled.get()) {
            if (pfd != null) runCatching { pfd.close() }
            if (cancelled.get()) teardown("cancelled", "cancelled") else {
                _phase.value = "failed"; fail("Не удалось создать VPN-интерфейс", "tunFailed"); breaker.recordFailure()
            }
            stopSelf(); return
        }
        tun = pfd
        ConsoleLog.log("ok", "TUN", "подсеть ${net.cidr}${if (net.collided) " (все кандидаты заняты!)" else ""}")

        // --- SSH пул ---
        _phase.value = "probe"
        val poolInst = SshConnectionPool(
            creds = {
                SshCredentials(prof.host, prof.port, prof.username, password, privKey, prof.hostKey.ifBlank { null })
            },
            socketProtect = { s -> try { protect(s) } catch (_: Exception) {} },
            onFirstPin = { pin ->
                scope.launch {
                    val cur = store.loadAll().firstOrNull { it.id == prof.id }
                    if (cur != null && cur.hostKey.isBlank()) store.save(cur.copy(hostKey = pin), null, null)
                }
            }
        )
        pool = poolInst
        val dialErr = suspendCancellableCoroutine<SshStartError?> { cont ->
            var resumed = false
            poolInst.connectFirst { ok, err ->
                if (!resumed) { resumed = true; cont.resume(if (ok) null else err) }
            }
        }
        if (cancelled.get()) {
            teardown("cancelled", "cancelled"); stopSelf(); return
        }
        if (dialErr != null) {
            _phase.value = "failed"
            fail("${dialErr.message} [${dialErr.code}]", dialErr.code)
            if (breaker.recordFailure()) {
                ConsoleLog.log("err", "BREAKER", "рубильник сработал: авто-дозвон остановлен до ручного Connect")
            }
            teardown("ssh failed: ${dialErr.code}", "error"); stopSelf(); return
        }
        // Egress self-test с вердиктом (порт TunnelSelfTest).
        poolInst.exec("curl -s -m 8 https://api.ipify.org || wget -qO- --timeout=8 https://api.ipify.org") { out, timedOut ->
            scope.launch(Dispatchers.IO) {
                val expected = try {
                    EgressTest.pickExpected(prof.host, listOfNotNull(runCatching {
                        java.net.InetAddress.getAllByName(prof.host).firstOrNull { it is java.net.Inet4Address }?.hostAddress
                    }.getOrNull()))
                } catch (_: Exception) { null }
                val verdict = if (timedOut) "self-test timed out"
                else when (val v = EgressTest.evaluate(expected, out)) {
                    is EgressVerdict.ViaServer -> "egress via server ✓"
                    is EgressVerdict.Bypass -> "egress BYPASS: ${v.observed} ⚠"
                    is EgressVerdict.Unparseable -> "egress unparseable (${v.reason})"
                    is EgressVerdict.UnknownExpected -> "egress: ${out.trim().take(64)}"
                }
                egressVerdict = verdict
                ConsoleLog.log("info", "SELFTEST", verdict)
            }
        }

        // --- Relay + DNS ---
        _phase.value = "transport"
        val lists = DnsListStore(this)
        lists.refreshStale()
        val dns = DnsRelay(poolInst, buildFilter(settings, lists), upstreamOf(prof, settings))
        dnsRelay = dns
        val machine = TcpRelayStateMachine(poolInst, SecureIsn())
        machine.onChannelData = { flow, data ->
            val pkts = machine.channelData(data, flow)
            pkts.forEach { toPhone.offer(it) }
        }
        machine.onChannelClose = { flow ->
            machine.channelClosed(flow).forEach { toPhone.offer(it) }
        }
        relay = machine

        // Живой пуш DNS без реконнекта (dnsRulesSet без IPC — один процесс).
        dnsJob?.cancel()
        dnsJob = scope.launch {
            liveDns.collect { cfg ->
                if (cfg != null && running) {
                    scope.launch(Dispatchers.IO) {
                        val curated = lists.curatedBlocks()
                        val merged = LocalDnsFilter(
                            exactBlocks = cfg.filter.exactBlocksSnapshot(),
                            subtreeBlocks = cfg.filter.subtreeBlocksSnapshot() + curated,
                            exactOverrides = cfg.filter.exactOverridesSnapshot(),
                            subtreeOverrides = cfg.filter.subtreeOverridesSnapshot()
                        )
                        dns.configure(merged, cfg.upstreams)
                        ConsoleLog.log("info", "DNS", "правила применены наживо (локальных+курируемых)")
                    }
                }
            }
        }

        running = true
        clearPersistedError()
        _phase.value = "ready"
        stopReason = "none"
        breaker.reset()
        ConsoleLog.log("ok", "TUN", "транспорт готов: ${prof.host}:${prof.port} (direct-tcpip)")
        loopJob = scope.launch { packetLoop(pfd) }
        scope.launch { statsLoop() }
        scope.launch { keepaliveLoop() }
    }

    private suspend fun buildFilter(settings: AppSettings, lists: DnsListStore): LocalDnsFilter {
        val rules = settings.dnsRules.map {
            DnsRule(it.domain, if (it.kind == "override") DnsRuleKind.OVERRIDE else DnsRuleKind.BLOCK, it.ip, it.sub)
        }
        val base = LocalDnsFilter(rules)
        val curated = try { lists.curatedBlocks() } catch (_: Exception) { emptySet() }
        if (curated.isEmpty()) return base
        return LocalDnsFilter(
            exactBlocks = base.exactBlocksSnapshot(), subtreeBlocks = base.subtreeBlocksSnapshot() + curated,
            exactOverrides = base.exactOverridesSnapshot(), subtreeOverrides = base.subtreeOverridesSnapshot()
        )
    }

    private fun upstreamOf(prof: com.ssh2vpn.android.data.ServerProfile, settings: AppSettings): List<String> {
        val per = prof.dnsServers.filter { AppSettings.isValidIpv4(it) }
        if (per.isNotEmpty()) return per
        return settings.validatedDnsServers.ifEmpty { listOf("8.8.8.8", "1.1.1.1") }
    }

    // ---------- Подсеть без коллизий (порт TunnelSubnetPicker) ----------

    data class SubnetChoice(val cidr: String, val deviceAddress: String, val gatewayAddress: String, val collided: Boolean)

    internal fun pickSubnet(): SubnetChoice {
        val androidId = try {
            android.provider.Settings.Secure.getString(contentResolver, android.provider.Settings.Secure.ANDROID_ID) ?: "ssh2vpn"
        } catch (_: Exception) { "ssh2vpn" }
        val digest = MessageDigest.getInstance("SHA-256").digest(androidId.toByteArray())
        val h1 = digest[0].toInt() and 0xFF
        val candidates = listOf(
            "10.203.$h1.2" to "10.203.$h1.0/24",
            "172.31.$h1.2" to "172.31.$h1.0/24",
            "192.168.${200 + h1 % 55}.2" to "192.168.${200 + h1 % 55}.0/24"
        )
        val occupied = occupiedNets()
        for ((dev, cidr) in candidates) {
            if (occupied.none { overlaps(it, cidr) }) {
                val gw = dev.substringBeforeLast(".") + ".1"
                return SubnetChoice(cidr, dev, gw, false)
            }
        }
        val (dev, cidr) = candidates[0]
        ConsoleLog.log("warn", "TUN", "все подсети-кандидаты заняты, беру primary $cidr")
        return SubnetChoice(cidr, dev, dev.substringBeforeLast(".") + ".1", true)
    }

    private fun occupiedNets(): List<String> {
        return try {
            NetworkInterface.getNetworkInterfaces()?.toList()
                ?.filter { it.isUp && !it.isLoopback }
                ?.flatMap { ni -> ni.interfaceAddresses.mapNotNull { ia ->
                    val addr = ia.address?.hostAddress ?: return@mapNotNull null
                    if (':' in addr) null else "$addr/${ia.networkPrefixLength}"
                } } ?: emptyList()
        } catch (_: Exception) { emptyList() }
    }

    private fun overlaps(occupiedCidr: String, candidateCidr: String): Boolean {
        fun parse(c: String): Pair<Long, Int> {
            val ip = c.substringBefore("/"); val p = c.substringAfter("/").toIntOrNull() ?: 32
            val v = ip.split(".").fold(0L) { a, o -> (a shl 8) or ((o.toIntOrNull() ?: 0) and 0xFF).toLong() }
            return v to p
        }
        return try {
            val (a, pa) = parse(occupiedCidr); val (b, pb) = parse(candidateCidr)
            val short = minOf(pa, pb)
            if (short <= 0) return true
            val mask = (0xFFFFFFFFL shl (32 - short)) and 0xFFFFFFFFL
            (a and mask) == (b and mask)
        } catch (_: Exception) { false }
    }

    // ---------- Packet loop ----------

    private suspend fun packetLoop(pfd: ParcelFileDescriptor) {
        val inp = FileInputStream(pfd.fileDescriptor)
        val out = FileOutputStream(pfd.fileDescriptor)
        val buf = ByteArray(65535)
        val writer = scope.launch(Dispatchers.IO) {
            while (running) {
                try {
                    val pkt = toPhone.take()
                    out.write(pkt); out.flush()
                } catch (_: Exception) { break }
            }
        }
        val sweeper = scope.launch {
            var emptyPoolTicks = 0
            var frozenTicks = 0
            var lastSeenRead = 0L
            while (running) {
                delay(15_000)
                relay?.expireIdle()
                pool?.shrinkIdle()
                // Zombie/stall watchdog: пул мёртв несколько циклов подряд → teardown.
                if ((pool?.connectionCount() ?: 0) == 0) {
                    emptyPoolTicks++
                    if (emptyPoolTicks >= 8) {
                        ConsoleLog.log("err", "HEAL", "пул мёртв 2 мин — teardown (stalled)")
                        teardown("stalled", "stalled"); stopSelf(); break
                    }
                } else emptyPoolTicks = 0
                // Нет чтения из TUN 3+ мин при живом туннеле — мёртвый flow.
                if (lastReadAt == lastSeenRead && lastReadAt > 0) {
                    frozenTicks++
                    if (frozenTicks >= 12) {
                        ConsoleLog.log("err", "HEAL", "TUN молчит 3 мин — teardown (stalled)")
                        teardown("stalled", "stalled"); stopSelf(); break
                    }
                } else { frozenTicks = 0; lastSeenRead = lastReadAt }
            }
        }
        try {
            while (running) {
                val n = try { inp.read(buf) } catch (_: Exception) { break }
                if (n <= 0) continue
                val pkt = buf.copyOf(n)
                if (pkt.isEmpty()) continue
                packetsRead++
                lastReadAt = System.currentTimeMillis()
                classify(pkt)
                val ver = (pkt[0].toInt() ushr 4) and 0xF
                if (ver == 6) { v6Dropped++; continue }
                if (ver != 4) { nonIP++; continue }
                val proto = pkt.getOrNull(9)?.toInt()?.and(0xFF) ?: continue
                when (proto) {
                    6 -> {
                        val replies = try { relay?.handle(pkt) ?: emptyList() } catch (_: Exception) { emptyList() }
                        replies.forEach { toPhone.offer(it) }
                    }
                    17 -> handleUdp(pkt)
                    else -> { udpDropped++ }
                }
            }
        } finally {
            writer.cancel(); sweeper.cancel()
        }
    }

    private var v4tcp = 0L
    private var v4udp = 0L
    private fun classify(pkt: ByteArray) {
        if (pkt.size < 20 || ((pkt[0].toInt() ushr 4) and 0xF) != 4) return
        when (pkt[9].toInt() and 0xFF) {
            6 -> v4tcp++
            17 -> v4udp++
            else -> v4other++
        }
    }

    private fun handleUdp(pkt: ByteArray) {
        val parsed = try { Ipv4Parser.parse(pkt) } catch (_: Exception) { udpDropped++; return }
        if (parsed.flow.transport != IpTransport.UDP) return
        val ipLen = (pkt[0].toInt() and 0x0F) * 4
        val totalLen = Ipv4Parser.u16(pkt, 2)
        val dgram = pkt.copyOfRange(ipLen, min(totalLen, pkt.size))
        val udp = try { UdpParser.parse(dgram) } catch (_: Exception) { udpDropped++; return }
        if (udp.dstPort != 53) { udpDropped++; return }
        val respPayload = try { dnsRelay?.resolve(udp.payload) } catch (_: Exception) { null }
        if (respPayload == null) { udpDropped++; return }
        toPhone.offer(UdpParser.buildReply(parsed.flow, respPayload))
    }

    private suspend fun statsLoop() {
        while (running) {
            delay(1000)
            val r = relay
            _stats.value = Stats(
                upBytes = r?.totalUpBytes ?: 0L, downBytes = r?.totalDownBytes ?: 0L,
                flows = r?.flowCount ?: 0, channels = pool?.liveChannels() ?: 0,
                poolConns = pool?.connectionCount() ?: 0,
                udpDropped = udpDropped, v6Dropped = v6Dropped,
                dnsUpstream = dnsRelay?.answeredUpstream ?: 0,
                packetsRead = packetsRead, packetsWritten = 0,
                protoSplit = "v4tcp=$v4tcp v4udp=$v4udp v4other=$v4other v6=$v6Dropped nonIP=$nonIP",
                egress = egressVerdict, stopReason = stopReason
            )
        }
    }

    private suspend fun keepaliveLoop() {
        while (running) {
            delay(15_000)
            pool?.tick()
        }
    }

    private fun teardown(reason: String, stop: String) {
        running = false
        cancelled.set(true)
        stopReason = stop
        loopJob?.cancel(); loopJob = null
        dnsJob?.cancel(); dnsJob = null
        runCatching { pool?.closeAll() }
        runCatching { tun?.close() }
        tun = null
        _phase.value = "idle"
        ConsoleLog.log("info", "TUN", "остановлено: $reason")
    }

    override fun onDestroy() {
        teardown("destroy", if (stopReason == "none") "destroy" else stopReason)
        scope.cancel()
        super.onDestroy()
    }

    override fun onRevoke() {
        teardown("revoked by system", "revoked")
        super.onRevoke()
    }

    fun currentStopReason(): String = stopReason

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= 26) {
            val m = getSystemService(NotificationManager::class.java)
            m?.createNotificationChannel(NotificationChannel("vpn", "VPN", NotificationManager.IMPORTANCE_LOW))
        }
    }
    private fun startForegroundCompat() {
        val pi = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val n: Notification = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, "vpn")
                .setContentTitle(getString(R.string.app_name))
                .setContentText(getString(R.string.vpn_connecting))
                .setSmallIcon(android.R.drawable.ic_lock_lock)
                .setContentIntent(pi).build()
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setContentTitle(getString(R.string.app_name))
                .setContentText(getString(R.string.vpn_connecting))
                .setSmallIcon(android.R.drawable.ic_lock_lock)
                .setContentIntent(pi).build()
        }
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(1, n, android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(1, n)
        }
    }
}
