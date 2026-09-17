package com.ssh2vpn.android.core

/** Ключ TCP-флоу — зеркало RelayFlow из iOS. */
data class RelayFlow(
    val srcAddr: ByteArray, val srcPort: Int,
    val dstAddr: ByteArray, val dstPort: Int
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is RelayFlow) return false
        return srcPort == other.srcPort && dstPort == other.dstPort &&
            srcAddr.contentEquals(other.srcAddr) && dstAddr.contentEquals(other.dstAddr)
    }
    override fun hashCode(): Int {
        var r = srcAddr.contentHashCode()
        r = 31 * r + srcPort; r = 31 * r + dstAddr.contentHashCode(); r = 31 * r + dstPort
        return r
    }
    fun toIpv4Flow(): Ipv4Flow {
        fun ByteArray.toInt32(): Int =
            ((this[0].toInt() and 0xFF) shl 24) or ((this[1].toInt() and 0xFF) shl 16) or
                ((this[2].toInt() and 0xFF) shl 8) or (this[3].toInt() and 0xFF)
        return Ipv4Flow(srcAddr.toInt32(), srcPort, dstAddr.toInt32(), dstPort, IpTransport.TCP)
    }
    fun ipFlow(): Ipv4Flow = toIpv4Flow()
}

/** Абстракция relay-канала: один SSH direct-tcpip канал. */
interface RelayChannel { fun send(data: ByteArray); fun close() }
interface RelayChannelFactory {
    fun open(flow: RelayFlow, onData: (ByteArray) -> Unit, onClosed: () -> Unit): RelayChannel
}
interface IsnGenerator { fun next(): Long }

enum class RelayFlowState { SYN_RECEIVED, ESTABLISHED, CLOSING, CLOSED }

data class RelayFlowStats(val flow: RelayFlow, val state: RelayFlowState, val upBytes: Long, val downBytes: Long)

/**
 * TCP relay state machine — порт TCPRelayStateMachine.swift.
 * Та же семантика: sequence-aware, window scaling, backpressure,
 * half-close, дедуп/ooo-обработка, MSS-сегментация 1400.
 */
class TcpRelayStateMachine(
    private val factory: RelayChannelFactory,
    private val isnGenerator: IsnGenerator,
    private val idleTimeoutMs: Long = 60_000L
) {
    companion object { const val MAX_SEGMENT_PAYLOAD = 1400 }

    var onChannelData: ((RelayFlow, ByteArray) -> Unit)? = null
    var onChannelClose: ((RelayFlow) -> Unit)? = null

    private data class FlowState(
        var channel: RelayChannel,
        var state: RelayFlowState,
        var lastActivity: Long,
        var isn: Long,
        var peerSeq: Long,
        var peerRawWindow: Int = 65535,
        var peerWindowScale: Int = 0,
        var localSeq: Long,
        var localAck: Long,
        var outstandingToPhone: Long = 0,
        var phoneFinSeen: Boolean = false,
        var localFinSent: Boolean = false,
        var pendingToPhone: MutableList<ByteArray> = mutableListOf(),
        var upBytes: Long = 0, var downBytes: Long = 0
    ) {
        val effectivePeerWindow: Long get() = (peerRawWindow.toLong() and 0xFFFF) shl peerWindowScale
        val availablePeerWindow: Long get() {
            val w = effectivePeerWindow
            return if (w > outstandingToPhone) w - outstandingToPhone else 0
        }
    }

    private val flows = LinkedHashMap<RelayFlow, FlowState>()
    var totalUpBytes: Long = 0L; private set
    var totalDownBytes: Long = 0L; private set
    val flowCount: Int get() = synchronized(this) { flows.size }

    fun flowStats(): List<RelayFlowStats> = synchronized(this) {
        flows.map { (k, v) -> RelayFlowStats(k, v.state, v.upBytes, v.downBytes) }
    }

    /** Входящий IPv4-пакет из TUN. Возвращает пакеты-ответы телефону. */
    fun handle(packet: ByteArray): List<ByteArray> {
        val parsed = try { Ipv4Parser.parse(packet) } catch (_: Exception) { return emptyList() }
        if (parsed.flow.transport != IpTransport.TCP) return emptyList()
        val ipHeaderLen = (packet[0].toInt() and 0x0F) * 4
        val totalLen = Ipv4Parser.u16(packet, 2)
        if (ipHeaderLen < 20 || totalLen < ipHeaderLen || packet.size < totalLen) return emptyList()
        val seg = try { TcpParser.parse(packet.copyOfRange(ipHeaderLen, totalLen)) } catch (_: Exception) { return emptyList() }
        val key = RelayFlow(parsed.flow.srcBytes(), parsed.flow.srcPort, parsed.flow.dstBytes(), parsed.flow.dstPort)
        val ipFlow = key.ipFlow()

        if (seg.isRst) {
            synchronized(this) {
                flows[key]?.let { it.channel.close(); it.state = RelayFlowState.CLOSED }
            }
            return emptyList()
        }

        synchronized(this) {
            val st = flows[key]
            if (st != null) {
                st.lastActivity = now()
                // Новый SYN на живую/умершую запись (reuse порта): переоткрыть.
                if (seg.isSyn && st.state != RelayFlowState.SYN_RECEIVED) {
                    st.channel.close()
                    val isn = isnGenerator.next()
                    val fresh = FlowState(
                        channel = openChannel(key), state = RelayFlowState.SYN_RECEIVED,
                        lastActivity = now(), isn = isn, peerSeq = seg.seq,
                        localSeq = (isn + 1) and 0xFFFFFFFFL, localAck = (seg.seq + 1) and 0xFFFFFFFFL
                    )
                    fresh.peerWindowScale = seg.options.windowScale; fresh.peerRawWindow = seg.window
                    flows[key] = fresh
                    return listOf(TcpReplyBuilder.synAck(ipFlow, isn, seg.seq))
                }
                return when (st.state) {
                    RelayFlowState.SYN_RECEIVED -> handleSynReceived(st, ipFlow, seg)
                    RelayFlowState.ESTABLISHED -> handleEstablished(key, st, ipFlow, seg)
                    else -> emptyList()
                }
            }
            // Нет записи о флоу.
            if (seg.isSyn) {
                val isn = isnGenerator.next()
                val fresh = FlowState(
                    channel = openChannel(key), state = RelayFlowState.SYN_RECEIVED,
                    lastActivity = now(), isn = isn, peerSeq = seg.seq,
                    localSeq = (isn + 1) and 0xFFFFFFFFL, localAck = (seg.seq + 1) and 0xFFFFFFFFL
                )
                fresh.peerWindowScale = seg.options.windowScale; fresh.peerRawWindow = seg.window
                flows[key] = fresh
                return listOf(TcpReplyBuilder.synAck(ipFlow, isn, seg.seq))
            }
            // Чужой data/ACK без флоу — быстрый RST, чтобы телефон не висел (RFC 793 §3.4).
            val (rseq, rack) = if (seg.isAck) seg.ack to 0L else 0L to ((seg.seq + seg.payload.size) and 0xFFFFFFFFL)
            return listOf(TcpReplyBuilder.rst(ipFlow, rseq, rack))
        }
    }

    private fun handleSynReceived(st: FlowState, ipFlow: Ipv4Flow, seg: ParsedTcpSegment): List<ByteArray> {
        if (seg.isAck && !seg.isSyn) {
            st.state = RelayFlowState.ESTABLISHED
            st.peerSeq = seg.seq
            val out = mutableListOf<ByteArray>()
            for (chunk in st.pendingToPhone) out += spliceToPhone(chunk, ipFlow, st)
            st.pendingToPhone.clear()
            return out
        } else if (seg.isSyn) {
            return listOf(TcpReplyBuilder.synAck(ipFlow, st.isn, seg.seq))
        }
        return emptyList()
    }

    private fun handleEstablished(key: RelayFlow, st: FlowState, ipFlow: Ipv4Flow, seg: ParsedTcpSegment): List<ByteArray> {
        val replies = mutableListOf<ByteArray>()
        st.peerRawWindow = seg.window
        if (seg.isAck && TcpSequence.greaterThan(seg.ack, st.localAck)) {
            val acked = TcpSequence.distance(from = st.localAck, to = seg.ack)
            st.outstandingToPhone = if (acked > 0 && st.outstandingToPhone >= acked) st.outstandingToPhone - acked else 0
            st.localAck = seg.ack
            replies += flushPendingToPhone(st, ipFlow)
        }
        if (seg.isFin) {
            if (seg.payload.isNotEmpty()) forwardPhoneData(st, seg)
            st.peerSeq = ((seg.seq + seg.payload.size + 1) and 0xFFFFFFFFL)
            st.phoneFinSeen = true; st.state = RelayFlowState.CLOSING
            st.channel.close()
            replies += TcpReplyBuilder.data(ipFlow, st.localSeq, st.peerSeq, ByteArray(0))
            return replies
        }
        if (seg.payload.isEmpty()) return replies
        when (forwardPhoneData(st, seg)) {
            true -> replies += TcpReplyBuilder.data(ipFlow, st.localSeq, st.peerSeq, ByteArray(0))
            false -> replies += TcpReplyBuilder.data(ipFlow, st.localSeq, st.peerSeq, ByteArray(0))
        }
        return replies
    }

    /** true = новые данные ушли в канал; false = дубликат/ooo (ACK уже включён вызывающим). */
    private fun forwardPhoneData(st: FlowState, seg: ParsedTcpSegment): Boolean {
        val dist = TcpSequence.distance(from = st.peerSeq, to = seg.seq)
        val n = seg.payload.size
        if (dist == 0L) {
            st.channel.send(seg.payload)
            st.peerSeq = (seg.seq + n) and 0xFFFFFFFFL
            st.upBytes += n; totalUpBytes += n
            return true
        }
        if (dist < 0) {
            val overlap = ((st.peerSeq - seg.seq) and 0xFFFFFFFFL)
            if (overlap < n) {
                val fresh = seg.payload.copyOfRange(overlap.toInt(), n)
                st.channel.send(fresh)
                st.peerSeq = (seg.seq + n) and 0xFFFFFFFFL
                st.upBytes += fresh.size; totalUpBytes += fresh.size
            }
        }
        return false
    }

    /** Байты из SSH-канала -> телефону (с MSS-сегментацией и backpressure). */
    fun channelData(data: ByteArray, forFlow: RelayFlow): List<ByteArray> {
        synchronized(this) {
            val st = flows[forFlow] ?: return emptyList()
            st.lastActivity = now()
            return when (st.state) {
                RelayFlowState.ESTABLISHED -> spliceToPhone(data, forFlow.ipFlow(), st)
                RelayFlowState.CLOSING -> if (!st.localFinSent) spliceToPhone(data, forFlow.ipFlow(), st) else emptyList()
                RelayFlowState.SYN_RECEIVED -> { st.pendingToPhone.add(data); emptyList() }
                RelayFlowState.CLOSED -> emptyList()
            }
        }
    }

    private fun spliceToPhone(data: ByteArray, flow: Ipv4Flow, st: FlowState): List<ByteArray> {
        if (data.isEmpty()) return emptyList()
        if (st.availablePeerWindow == 0L) { st.pendingToPhone.add(data); return emptyList() }
        val avail = st.availablePeerWindow
        val toSend: ByteArray; val remainder: ByteArray
        if (avail > 0 && data.size > avail) {
            toSend = data.copyOfRange(0, avail.toInt()); remainder = data.copyOfRange(avail.toInt(), data.size)
        } else { toSend = data; remainder = ByteArray(0) }
        val out = mutableListOf<ByteArray>()
        var cursor = 0
        while (cursor < toSend.size) {
            val end = minOf(cursor + MAX_SEGMENT_PAYLOAD, toSend.size)
            val chunk = toSend.copyOfRange(cursor, end)
            out += TcpReplyBuilder.data(flow, st.localSeq, st.peerSeq, chunk)
            st.localSeq = (st.localSeq + chunk.size) and 0xFFFFFFFFL
            st.outstandingToPhone += chunk.size
            st.downBytes += chunk.size; totalDownBytes += chunk.size
            cursor = end
        }
        if (remainder.isNotEmpty()) st.pendingToPhone.add(remainder)
        return out
    }

    private fun flushPendingToPhone(st: FlowState, flow: Ipv4Flow): List<ByteArray> {
        if (st.pendingToPhone.isEmpty() || st.availablePeerWindow <= 0) return emptyList()
        var pending = ByteArray(0)
        for (c in st.pendingToPhone) pending += c
        st.pendingToPhone.clear()
        return spliceToPhone(pending, flow, st)
    }

    fun channelClosed(flow: RelayFlow): List<ByteArray> {
        synchronized(this) {
            val st = flows[flow] ?: return emptyList()
            if (st.state == RelayFlowState.CLOSED) return emptyList()
            st.state = RelayFlowState.CLOSING; st.lastActivity = now()
            val pkt = TcpReplyBuilder.fin(flow.ipFlow(), st.localSeq, st.peerSeq)
            st.localSeq = (st.localSeq + 1) and 0xFFFFFFFFL
            st.localFinSent = true
            return listOf(pkt)
        }
    }

    fun expireIdle(): Int {
        synchronized(this) {
            val t = now(); var n = 0
            for ((_, st) in flows) {
                if (t - st.lastActivity > idleTimeoutMs && st.state != RelayFlowState.CLOSED) {
                    st.channel.close(); st.state = RelayFlowState.CLOSED; n++
                }
            }
            return n
        }
    }

    private fun openChannel(key: RelayFlow): RelayChannel {
        val dataCb = onChannelData; val closeCb = onChannelClose
        return factory.open(key, { d -> dataCb?.invoke(key, d) }, { closeCb?.invoke(key) })
    }

    private fun now(): Long = System.currentTimeMillis()
}
