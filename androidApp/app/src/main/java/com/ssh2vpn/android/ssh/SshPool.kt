package com.ssh2vpn.android.ssh

import com.jcraft.jsch.ChannelDirectTCPIP
import com.jcraft.jsch.JSch
import com.jcraft.jsch.JSchException
import com.jcraft.jsch.Session
import com.ssh2vpn.android.core.IsnGenerator
import com.ssh2vpn.android.core.RelayChannel
import com.ssh2vpn.android.core.RelayChannelFactory
import com.ssh2vpn.android.core.RelayFlow
import com.ssh2vpn.android.core.SshStartError
import com.ssh2vpn.android.data.ConsoleLog
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.min
import kotlin.math.pow

// ---------- Чистая политика пула — порт SSHPoolPolicy / SSHGrowPacer / SSHPoolShrink ---

data class SshPoolPolicy(val maxConnections: Int = 8, val channelsPerConnection: Int = 9) {
    fun plan(inFlight: List<Int>): Int {
        require(inFlight.isNotEmpty())
        var best = 0
        for (i in inFlight.indices) if (inFlight[i] < inFlight[best]) best = i
        return best
    }
    fun desiredConnections(totalInFlight: Int): Int {
        val needed = (maxOf(1, totalInFlight) + channelsPerConnection - 1) / channelsPerConnection
        return min(maxConnections, needed)
    }
}

class SshGrowPacer(maxConcurrentDials: Int, minIntervalMs: Long) {
    private val maxConcurrent = maxOf(1, maxConcurrentDials)
    private val minInterval = maxOf(0L, minIntervalMs)
    private var inFlightDials = 0
    private var lastDialAt: Long = 0
    fun acquire(now: Long): Boolean {
        if (inFlightDials >= maxConcurrent) return false
        if (now - lastDialAt < minInterval) return false
        inFlightDials++; lastDialAt = now
        return true
    }
    fun settle() { inFlightDials = maxOf(0, inFlightDials - 1) }
}

object SshPoolShrink {
    fun evictionIndexes(inFlight: List<Int>, idleSince: List<Long?>, now: Long, idleTimeoutMs: Long, minConnections: Int): List<Int> {
        if (idleTimeoutMs <= 0) return emptyList()
        val keepMin = maxOf(1, minConnections)
        val count = minOf(inFlight.size, idleSince.size)
        if (count <= keepMin) return emptyList()
        val cand = mutableListOf<Pair<Int, Long>>()
        for (i in 0 until count) {
            val since = idleSince[i] ?: continue
            if (inFlight[i] == 0 && now - since >= idleTimeoutMs) cand.add(i to since)
        }
        val evictable = minOf(count - keepMin, cand.size)
        return cand.sortedBy { it.second }.take(evictable).map { it.first }.sorted()
    }
}

// ---------- JSch direct-tcpip канал (единственный тип каналов в приложении) ---

/**
 * Один SSH direct-tcpip канал через JSch: открывается строго командой
 * "direct-tcpip" к целевому host:port. Поддерживает rebind для переиспользования
 * прогретого (spare) канала: данные, пришедшие до rebind, буферизуются.
 */
private class JschDirectChannel(
    private val open: () -> ChannelDirectTCPIP,
    private val log: (String) -> Unit
) : RelayChannel {
    @Volatile private var ch: ChannelDirectTCPIP? = null
    @Volatile private var out: OutputStream? = null
    @Volatile private var closed = false
    @Volatile private var onData: ((ByteArray) -> Unit)? = null
    @Volatile private var onClosed: (() -> Unit)? = null
    private val buffered = ArrayDeque<ByteArray>()
    private var bufferedBytes = 0
    private var pump: Thread? = null

    /** Открыть канал. false = не открылся (вызывающий чистит учёт). */
    fun start(targetHost: String, targetPort: Int, data: (ByteArray) -> Unit, closedCb: () -> Unit): Boolean {
        onData = data; onClosed = closedCb
        try {
            val c = open()
            c.setHost(targetHost); c.setPort(targetPort)
            val inp: InputStream = c.inputStream
            out = c.outputStream
            c.connect(10_000)
            ch = c
            pump = Thread({
                val buf = ByteArray(32 * 1024)
                try {
                    while (!closed && c.isConnected) {
                        val n = inp.read(buf)
                        if (n < 0) break
                        if (n > 0) deliver(buf.copyOf(n))
                    }
                } catch (_: Exception) {
                } finally {
                    close()
                    onClosed?.invoke()
                }
            }, "ssh-direct-pump").also { it.isDaemon = true; it.start() }
            return true
        } catch (e: Exception) {
            log("direct-tcpip open FAILED $targetHost:$targetPort: ${e.message}")
            close()
            return false
        }
    }

    /** Прицепить прогревной канал к новому флоу. false = канал мёртв. */
    fun rebind(data: (ByteArray) -> Unit, closedCb: () -> Unit): Boolean {
        val c = ch
        if (closed || c == null || !c.isConnected) return false
        onClosed = closedCb
        synchronized(buffered) {
            onData = data
            while (buffered.isNotEmpty()) {
                val b = buffered.removeFirst()
                bufferedBytes -= b.size
                try { data(b) } catch (_: Exception) {}
            }
        }
        return true
    }

    fun isAlive(): Boolean {
        val c = ch
        return !closed && c != null && c.isConnected
    }

    private fun deliver(b: ByteArray) {
        val cb = onData
        if (cb != null) {
            try { cb(b) } catch (_: Exception) {}
        } else {
            // Прогревной канал: сервер молчит, но на всякий случай буферизуем (cap 64K).
            synchronized(buffered) {
                if (bufferedBytes + b.size <= 64 * 1024) {
                    buffered.addLast(b); bufferedBytes += b.size
                }
            }
        }
    }

    override fun send(data: ByteArray) {
        try { out?.write(data); out?.flush() } catch (_: Exception) { }
    }

    override fun close() {
        if (closed) return
        closed = true
        try { ch?.disconnect() } catch (_: Exception) { }
    }
}

private class DeadChannel : RelayChannel {
    override fun send(data: ByteArray) {}
    override fun close() {}
}

// ---------- Пул SSH-соединений ---

data class SshCredentials(
    val host: String, val port: Int, val username: String,
    val password: String?,
    /** Оригинальный текст OpenSSH-ключа (только незашифрованный Ed25519, проверен SshKeyParser). */
    val privateKeyPem: String?,
    val pinnedHostKey: String?
)

sealed interface ProbeResult {
    object Ok : ProbeResult
    object ForwardingRefused : ProbeResult
    class EgressBlocked(val tried: List<String>) : ProbeResult
}

class SshConnectionPool(
    private val creds: () -> SshCredentials,
    private val policy: SshPoolPolicy = SshPoolPolicy(),
    private val socketProtect: (java.net.Socket) -> Unit = {},
    private val onFirstPin: (pin: String) -> Unit = {},
    private val log: (level: String, tag: String, msg: String) -> Unit = { l, t, m -> ConsoleLog.log(l, t, m) }
) : RelayChannelFactory {

    private data class Entry(
        var session: Session, var inFlight: Int,
        var idleSince: Long?, var bytesSinceRekey: Long = 0,
        val startedAt: Long = System.currentTimeMillis()
    )

    private data class Spare(val jc: JschDirectChannel, val parkedAt: Long)

    private val lock = Any()
    private val entries = mutableListOf<Entry>()
    private val spares = mutableMapOf<String, ArrayDeque<Spare>>()
    private var pendingGrows = 0
    private var closed = false
    private var healAttempts = 0
    private var lastMismatch: Pair<String, String>? = null
    private val pacer = SshGrowPacer(3, 400)
    private val bg = Executors.newCachedThreadPool { r -> Thread(r, "ssh-pool").apply { isDaemon = true } }
    private val channelCount = AtomicInteger(0)
    private val totalBytes = AtomicLong(0)
    // Keepalive с suppression (P-15): шлём, только если релей простаивает 60с+.
    private var lastTrafficBytes = 0L
    private var lastKeepaliveAt = 0L

    fun connectionCount(): Int = synchronized(lock) { entries.size }
    fun liveChannels(): Int = channelCount.get()
    fun totalBytesRelayed(): Long = totalBytes.get()
    fun isClosed(): Boolean = synchronized(lock) { closed }

    /** Первое соединение + pre-flight probe. Ошибка — типизированная (fatal без ретрая). */
    fun connectFirst(onDone: (ok: Boolean, error: SshStartError?) -> Unit) {
        bg.execute {
            val s = try {
                dial()
            } catch (e: SshStartError) {
                onDone(false, e); return@execute
            } catch (e: Exception) {
                onDone(false, SshStartError.Transient("SSH: ${e.message ?: e.javaClass.simpleName}")); return@execute
            }
            val entry = Entry(s, 0, System.currentTimeMillis())
            synchronized(lock) {
                if (closed) {
                    runCatching { s.disconnect() }
                    return@execute
                }
                entries.add(entry)
            }
            log("ok", "POOL", "ssh#1 ready")
            when (val p = probe()) {
                is ProbeResult.Ok -> onDone(true, null)
                is ProbeResult.ForwardingRefused ->
                    onDone(false, SshStartError.ForwardingRefused("8.8.8.8", 53, "direct-tcpip open отклонён"))
                is ProbeResult.EgressBlocked ->
                    onDone(false, SshStartError.EgressBlocked(p.tried))
            }
        }
    }

    /**
     * Pre-flight probe как в iOS §13 + localhost-fallback:
     * 8.8.8.8/1.1.1.1 мертвы, а 127.0.0.1:22 жив → forwarding работает,
     * но нет egress (EgressBlocked); мертво всё → ForwardingRefused.
     */
    private fun probe(): ProbeResult {
        if (tryDirect(listOf("8.8.8.8" to 53, "1.1.1.1" to 53))) return ProbeResult.Ok
        if (tryDirect(listOf("127.0.0.1" to 22))) {
            return ProbeResult.EgressBlocked(listOf("8.8.8.8:53", "1.1.1.1:53"))
        }
        return ProbeResult.ForwardingRefused
    }

    private fun tryDirect(targets: List<Pair<String, Int>>): Boolean {
        val e = synchronized(lock) { entries.firstOrNull() } ?: return false
        for ((h, p) in targets) {
            try {
                val c = e.session.openChannel("direct-tcpip") as ChannelDirectTCPIP
                c.setHost(h); c.setPort(p)
                c.connect(5_000)
                c.disconnect()
                return true
            } catch (_: Exception) { }
        }
        return false
    }

    private fun dial(): Session {
        val c = creds()
        val jsch = JSch()
        c.privateKeyPem?.let { pem ->
            jsch.addIdentity("ed25519", pem.trim().toByteArray(Charsets.US_ASCII), null, null)
        }
        val s = jsch.getSession(c.username, c.host, c.port)
        c.password?.let { s.setPassword(it) }
        lastMismatch = null
        val repo = PinnedHostKeyRepository(c.pinnedHostKey) { exp, got ->
            lastMismatch = exp to got
            log("err", "SSH", "host key mismatch: expected $exp got $got")
        }
        s.setHostKeyRepository(repo)
        s.setConfig("StrictHostKeyChecking", "no")
        s.setConfig("PreferredAuthentications", "publickey,password,keyboard-interactive")
        // JSch keepalive на уровне TCP (протокольный global request шлём сами в tick).
        s.setServerAliveInterval(15_000)
        s.setServerAliveCountMax(3)
        s.setSocketFactory(object : com.jcraft.jsch.SocketFactory {
            override fun createSocket(host: String?, port: Int): java.net.Socket {
                val sock = java.net.Socket()
                sock.tcpNoDelay = true
                sock.connect(java.net.InetSocketAddress(host, port), 10_000)
                try { socketProtect(sock) } catch (_: Exception) {}
                return sock
            }
            override fun getInputStream(s: java.net.Socket?) = s!!.getInputStream()
            override fun getOutputStream(s: java.net.Socket?) = s!!.getOutputStream()
        })
        try {
            s.connect(15_000)
        } catch (e: JSchException) {
            val m = e.message.orEmpty()
            val ml = m.lowercase()
            lastMismatch?.let { (exp, got) ->
                lastMismatch = null
                throw SshStartError.HostKeyMismatch(exp, got)
            }
            throw when {
                "auth fail" in m || "USERAUTH fail" in m ->
                    SshStartError.AuthFailed(m)
                "UnknownHostException" in m || "unresolved" in ml ->
                    SshStartError.Transient("Хост не найден. Проверьте адрес сервера.")
                "timeout" in ml || "timed out" in ml ->
                    SshStartError.Transient("Сервер недоступен (таймаут). Проверьте IP/порт и сеть.")
                "refused" in ml ->
                    SshStartError.Transient("SSH-порт закрыт или sshd не запущен.")
                else -> SshStartError.Transient("SSH: $m")
            }
        }
        repo.pinnedKey()?.let { onFirstPin(it) }
        return s
    }

    // RelayChannelFactory: каждый TCP-флоу -> least-loaded direct-tcpip.
    override fun open(flow: RelayFlow, onData: (ByteArray) -> Unit, onClosed: () -> Unit): RelayChannel {
        val host = flow.dstAddr.joinToString(".") { (it.toInt() and 0xFF).toString() }
        return openTo(flow, host, flow.dstPort, onData, onClosed)
    }

    /** DNS-путь: upstream-хост задаётся явно (запрос пришёл на IP самого TUN). */
    fun openTo(flow: RelayFlow, targetHost: String, targetPort: Int, onData: (ByteArray) -> Unit, onClosed: () -> Unit): RelayChannel {
        val entry: Entry
        synchronized(lock) {
            if (closed || entries.isEmpty()) {
                if (!closed) heal()
                return DeadChannel()
            }
            val idx = policy.plan(entries.map { it.inFlight })
            entries[idx].inFlight++
            entries[idx].idleSince = null
            entry = entries[idx]
            val total = entries.sumOf { it.inFlight }
            val deficit = policy.desiredConnections(total) - entries.size - pendingGrows
            val now = System.currentTimeMillis()
            var launched = 0
            repeat(maxOf(0, deficit)) {
                if (pacer.acquire(now)) { pendingGrows++; launched++ }
            }
            repeat(launched) { launchGrow() }
            log("info", "POOL", "flow ${flow.describeShort()} via ssh#${idx + 1}")
        }
        val counted: (ByteArray) -> Unit = { d ->
            noteBytes(entry, d.size.toLong())
            onData(d)
        }
        // Прогревной spare для мгновенного старта (эквивалент WarmChannelPool).
        val spareKey = "$targetHost:$targetPort"
        val spare = takeSpare(spareKey)
        val released = AtomicBoolean(false)
        val releaseOnce = {
            if (released.compareAndSet(false, true)) {
                channelCount.decrementAndGet()
                synchronized(lock) {
                    val i = entries.indexOf(entry)
                    if (i >= 0 && entries[i].inFlight > 0) {
                        entries[i].inFlight--
                        if (entries[i].inFlight == 0 && entries[i].idleSince == null) entries[i].idleSince = System.currentTimeMillis()
                    }
                }
            }
            Unit
        }
        if (spare != null) {
            channelCount.incrementAndGet()
            if (spare.rebind(counted) { releaseOnce(); onClosed() }) {
                refillSpare(entry, spareKey)
                return channelRelay(spare, entry, releaseOnce)
            }
            spare.close()
            releaseOnce()
        }
        val jc = JschDirectChannel(
            open = {
                synchronized(lock) { entry.session.openChannel("direct-tcpip") as ChannelDirectTCPIP }
            },
            log = { m -> log("warn", "POOL", m) }
        )
        channelCount.incrementAndGet()
        if (!jc.start(targetHost, targetPort, counted) { releaseOnce(); onClosed() }) {
            releaseOnce()
            onClosed()
            return DeadChannel()
        }
        refillSpare(entry, spareKey)
        return channelRelay(jc, entry, releaseOnce)
    }

    private fun channelRelay(jc: JschDirectChannel, entry: Entry, releaseOnce: () -> Unit): RelayChannel =
        object : RelayChannel {
            override fun send(data: ByteArray) {
                noteBytes(entry, data.size.toLong())
                jc.send(data)
            }
            override fun close() = jc.close()
        }

    private fun noteBytes(entry: Entry, n: Long) {
        if (n <= 0) return
        totalBytes.addAndGet(n)
        synchronized(lock) { entry.bytesSinceRekey += n }
    }

    private fun takeSpare(key: String): JschDirectChannel? {
        synchronized(lock) {
            val q = spares[key] ?: return null
            while (q.isNotEmpty()) {
                val s = q.removeFirst()
                if (s.jc.isAlive() && System.currentTimeMillis() - s.parkedAt < 15_000) return s.jc
                try { s.jc.close() } catch (_: Exception) {}
            }
            return null
        }
    }

    /** Держать ≤2 прогретых spare-каналов: следующий SYN стартует за ~0 RTT. */
    private fun refillSpare(entry: Entry, key: String) {
        val parts = key.split(":")
        if (parts.size != 2) return
        val host = parts[0]; val port = parts[1].toIntOrNull() ?: return
        val total = synchronized(lock) { spares.values.sumOf { it.size } }
        if (total >= 2) return
        bg.execute {
            if (isClosed()) return@execute
            val jc = JschDirectChannel(
                open = {
                    synchronized(lock) { entry.session.openChannel("direct-tcpip") as ChannelDirectTCPIP }
                },
                log = {}
            )
            if (!jc.start(host, port, {}, {})) return@execute
            synchronized(lock) {
                if (closed || spares.values.sumOf { it.size } >= 2) {
                    try { jc.close() } catch (_: Exception) {}
                    return@execute
                }
                spares.getOrPut(key) { ArrayDeque() }.addLast(Spare(jc, System.currentTimeMillis()))
            }
        }
    }

    /**
     * Периодический тик (сервис дёргает каждые 15с):
     * - выкидывает мёртвые сессии (isConnected=false) + heal при пустом пуле;
     * - keepalive `keepalive@openssh.com`-эквивалент, только если релей
     *   простаивает 60с+ (suppression как в SSHKeepalivePolicy);
     * - rekey-recycle: соединения старше 1ч / прокачавшие 4G+, свободные и
     *   сверх baseline — пересоздаются (JSch не умеет rekey in place).
     */
    fun tick() {
        val now = System.currentTimeMillis()
        var needHeal = false
        synchronized(lock) {
            if (!closed) {
                val it = entries.iterator()
                var dropped = 0
                while (it.hasNext()) {
                    val e = it.next()
                    if (!e.session.isConnected) {
                        it.remove(); dropped++
                        runCatching { e.session.disconnect() }
                    }
                }
                if (dropped > 0) log("warn", "POOL", "выкинуто мёртвых сессий: $dropped")
                // Rekey-recycle (OpenSSH RekeyLimit 4G/1h): свободные соединения
                // старше порога и сверх baseline уходят; JSch не умеет rekey in place.
                val recyc = entries.indices.filter { i ->
                    val e = entries[i]
                    entries.size > 2 && e.inFlight == 0 &&
                        (e.bytesSinceRekey >= 4L * 1024 * 1024 * 1024 || now - e.startedAt >= 3_600_000)
                }.take(1)
                for (i in recyc.sortedDescending()) {
                    val e = entries.removeAt(i)
                    runCatching { e.session.disconnect() }
                    log("info", "POOL", "rekey-recycle: сессия пересоздастся по требованию")
                }
                if (entries.isEmpty()) needHeal = true
            }
        }
        if (needHeal) {
            log("err", "POOL", "пул пуст — heal")
            heal()
            return
        }
        val bytes = totalBytes.get()
        if (bytes == lastTrafficBytes && now - lastKeepaliveAt >= 60_000) {
            lastKeepaliveAt = now
            val snap = synchronized(lock) { entries.toList() }
            for (e in snap) {
                bg.execute {
                    try { e.session.sendKeepAliveMsg() } catch (_: Exception) { }
                }
            }
        } else if (bytes != lastTrafficBytes) {
            lastTrafficBytes = bytes
        }
    }

    fun keepaliveTick() = tick()

    fun shrinkIdle(idleTimeoutMs: Long = 60_000, minConnections: Int = 2) {
        val toEvict: List<Entry>
        synchronized(lock) {
            val idx = SshPoolShrink.evictionIndexes(
                entries.map { it.inFlight }, entries.map { it.idleSince },
                System.currentTimeMillis(), idleTimeoutMs, minConnections
            )
            if (closed || idx.isEmpty()) return
            toEvict = idx.sortedDescending().map { entries.removeAt(it) }
        }
        toEvict.forEach { runCatching { it.session.disconnect() } }
        log("ok", "POOL", "idle shrink: закрыто ${toEvict.size}, осталось ${connectionCount()}")
    }

    fun exec(command: String, timeoutMs: Long = 15_000, done: (String, Boolean) -> Unit) {
        bg.execute {
            try {
                val e = synchronized(lock) { entries.firstOrNull { it.session.isConnected } } ?: run {
                    done("", false); return@execute
                }
                val c = e.session.openChannel("exec") as com.jcraft.jsch.ChannelExec
                c.setCommand(command)
                val out = c.inputStream
                c.connect(5_000)
                val t0 = System.currentTimeMillis()
                val sb = StringBuilder()
                val buf = ByteArray(8192)
                while (!c.isClosed && System.currentTimeMillis() - t0 < timeoutMs) {
                    while (out.available() > 0) {
                        val n = out.read(buf)
                        if (n > 0) sb.append(String(buf, 0, n, Charsets.UTF_8))
                    }
                    Thread.sleep(50)
                }
                while (out.available() > 0) {
                    val n = out.read(buf)
                    if (n <= 0) break
                    sb.append(String(buf, 0, n, Charsets.UTF_8))
                }
                val timedOut = !c.isClosed
                c.disconnect()
                done(sb.toString(), timedOut)
            } catch (_: Exception) { done("", false) }
        }
    }

    fun closeAll() {
        val snap: List<Entry>
        val spareSnap: List<JschDirectChannel>
        synchronized(lock) {
            if (closed) return
            closed = true
            snap = entries.toList(); entries.clear()
            spareSnap = spares.values.flatten().map { it.jc }
            spares.clear()
        }
        (snap.map { it.session }).forEach { runCatching { it.disconnect() } }
        spareSnap.forEach { runCatching { it.close() } }
    }

    private fun launchGrow() {
        bg.execute {
            try {
                val s = dial()
                synchronized(lock) {
                    pendingGrows--
                    pacer.settle()
                    if (!closed) {
                        entries.add(Entry(s, 0, null))
                        log("ok", "POOL", "параллельное SSH #${entries.size} готово")
                    } else runCatching { s.disconnect() }
                }
            } catch (e: SshStartError) {
                synchronized(lock) { pendingGrows--; pacer.settle() }
                log("warn", "POOL", "параллельное SSH не поднялось [${e.code}]: ${e.message}")
            } catch (e: Exception) {
                synchronized(lock) { pendingGrows--; pacer.settle() }
                log("warn", "POOL", "параллельное SSH не поднялось: ${e.message}")
            }
        }
    }

    private fun heal() {
        synchronized(lock) {
            if (closed || pendingGrows > 0) return
            healAttempts++
            pendingGrows++
        }
        val delay = min(3600.0, 2.0.pow((healAttempts - 1).toDouble())).toLong()
        bg.execute {
            if (healAttempts > 1) Thread.sleep(delay * 1000)
            try {
                val s = dial()
                synchronized(lock) {
                    pendingGrows--
                    if (!closed) {
                        entries.add(Entry(s, 0, null)); healAttempts = 0
                        log("ok", "POOL", "SSH восстановлено")
                    } else runCatching { s.disconnect() }
                }
            } catch (e: SshStartError) {
                synchronized(lock) { pendingGrows-- }
                // Fatal-ошибки heal не ретраит штормом: одна запись в лог, дальше
                // только ручной коннект (защита от fail2ban, как в iOS).
                log("err", "POOL", "heal [${e.code}]: ${e.message}")
            } catch (e: Exception) {
                synchronized(lock) { pendingGrows-- }
                log("err", "POOL", "heal failed: ${e.message}")
            }
        }
    }

    private fun RelayFlow.describeShort(): String {
        fun ByteArray.ip() = joinToString(".") { (it.toInt() and 0xFF).toString() }
        return "${srcAddr.ip()}:$srcPort -> ${dstAddr.ip()}:$dstPort"
    }
}

/** ISN-генератор для SYN-ACK. */
class SecureIsn : IsnGenerator {
    private val r = java.security.SecureRandom()
    override fun next(): Long = (r.nextInt().toLong() and 0xFFFFFFFFL)
}
