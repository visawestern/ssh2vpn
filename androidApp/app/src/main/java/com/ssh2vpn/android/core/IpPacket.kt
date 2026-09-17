package com.ssh2vpn.android.core

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Ошибки парсинга IPv4 — зеркало IPPacketError из iOS. */
sealed class IpPacketError(message: String) : Exception(message) {
    object Empty : IpPacketError("empty")
    object UnsupportedVersion : IpPacketError("unsupported version (not IPv4)")
    object InvalidHeaderLength : IpPacketError("invalid header length")
    object Truncated : IpPacketError("truncated")
    object InvalidTotalLength : IpPacketError("invalid total length")
    object UnsupportedProtocol : IpPacketError("unsupported protocol (not TCP/UDP)")
}

enum class IpTransport(val number: Int) { TCP(6), UDP(17) }

data class Ipv4Flow(
    val srcAddr: Int,
    val srcPort: Int,
    val dstAddr: Int,
    val dstPort: Int,
    val transport: IpTransport
) {
    fun srcBytes(): ByteArray = byteArrayOf(
        (srcAddr ushr 24).toByte(), ((srcAddr ushr 16) and 0xFF).toByte(),
        ((srcAddr ushr 8) and 0xFF).toByte(), (srcAddr and 0xFF).toByte()
    )
    fun dstBytes(): ByteArray = byteArrayOf(
        (dstAddr ushr 24).toByte(), ((dstAddr ushr 16) and 0xFF).toByte(),
        ((dstAddr ushr 8) and 0xFF).toByte(), (dstAddr and 0xFF).toByte()
    )
    fun describe(): String {
        fun Int.ip(): String = "${(this ushr 24) and 0xFF}.${(this ushr 16) and 0xFF}.${(this ushr 8) and 0xFF}.${this and 0xFF}"
        return "${srcAddr.ip()}:$srcPort -> ${dstAddr.ip()}:$dstPort"
    }
}

data class ParsedIpv4Packet(val flow: Ipv4Flow, val header: ByteArray, val payload: ByteArray)

/** Парсер IPv4 — порт IPv4Parser.swift 1-в-1. */
object Ipv4Parser {
    fun parse(packet: ByteArray): ParsedIpv4Packet {
        if (packet.size < 20) throw IpPacketError.Empty
        val version = (packet[0].toInt() ushr 4) and 0xF
        if (version != 4) throw IpPacketError.UnsupportedVersion
        val headerLen = (packet[0].toInt() and 0x0F) * 4
        if (headerLen < 20) throw IpPacketError.InvalidHeaderLength
        if (packet.size < headerLen) throw IpPacketError.Truncated
        val totalLen = ((packet[2].toInt() and 0xFF) shl 8) or (packet[3].toInt() and 0xFF)
        if (totalLen < headerLen || totalLen > packet.size) throw IpPacketError.InvalidTotalLength
        val transport = when (packet[9].toInt() and 0xFF) {
            6 -> IpTransport.TCP
            17 -> IpTransport.UDP
            else -> throw IpPacketError.UnsupportedProtocol
        }
        val tOff = headerLen
        val tMin = if (transport == IpTransport.TCP) 20 else 8
        if (totalLen < tOff + tMin) throw IpPacketError.Truncated
        val srcPort = u16(packet, tOff)
        val dstPort = u16(packet, tOff + 2)
        val srcAddr = u32(packet, 12)
        val dstAddr = u32(packet, 16)
        val flow = Ipv4Flow(srcAddr, srcPort, dstAddr, dstPort, transport)
        val payloadOff = if (transport == IpTransport.TCP) {
            tOff + (((packet[tOff + 12].toInt() ushr 4) and 0xF) * 4)
        } else tOff + 8
        if (payloadOff < tOff + tMin || payloadOff > totalLen) throw IpPacketError.InvalidHeaderLength
        return ParsedIpv4Packet(
            flow,
            packet.copyOfRange(0, payloadOff),
            packet.copyOfRange(payloadOff, totalLen)
        )
    }

    internal fun u16(b: ByteArray, i: Int) = ((b[i].toInt() and 0xFF) shl 8) or (b[i + 1].toInt() and 0xFF)
    internal fun u32(b: ByteArray, i: Int): Int =
        ((b[i].toInt() and 0xFF) shl 24) or ((b[i + 1].toInt() and 0xFF) shl 16) or
            ((b[i + 2].toInt() and 0xFF) shl 8) or (b[i + 3].toInt() and 0xFF)
}

// ---------- TCP ----------

data class TcpOptions(val windowScale: Int)

data class ParsedTcpSegment(
    val seq: Long, val ack: Long, val flags: Int, val window: Int,
    val options: TcpOptions, val payload: ByteArray
) {
    val isSyn: Boolean get() = flags and 0x02 != 0
    val isAck: Boolean get() = flags and 0x10 != 0
    val isFin: Boolean get() = flags and 0x01 != 0
    val isRst: Boolean get() = flags and 0x04 != 0
}

object TcpParser {
    const val FIN = 0x01; const val SYN = 0x02; const val RST = 0x04
    const val PSH = 0x08; const val ACK = 0x10

    fun parse(seg: ByteArray): ParsedTcpSegment {
        require(seg.size >= 20) { "tcp truncated" }
        val bb = ByteBuffer.wrap(seg).order(ByteOrder.BIG_ENDIAN)
        bb.position(4)
        val seq = bb.int.toLong() and 0xFFFFFFFFL
        val ack = bb.int.toLong() and 0xFFFFFFFFL
        val dataOff = ((seg[12].toInt() ushr 4) and 0xF) * 4
        require(dataOff >= 20 && dataOff <= seg.size) { "tcp bad data offset" }
        val flags = seg[13].toInt() and 0x3F
        val window = ((seg[14].toInt() and 0xFF) shl 8) or (seg[15].toInt() and 0xFF)
        var wscale = 0
        var i = 20
        while (i < dataOff) {
            val kind = seg[i].toInt() and 0xFF
            if (kind == 0) break
            if (kind == 1) { i++; continue }
            if (i + 1 >= dataOff) break
            val len = seg[i + 1].toInt() and 0xFF
            if (len < 2 || i + len > dataOff) break
            if (kind == 3 && len == 3) wscale = (seg[i + 2].toInt() and 0xFF).coerceIn(0, 14)
            i += len
        }
        return ParsedTcpSegment(seq, ack, flags, window, TcpOptions(wscale), seg.copyOfRange(dataOff, seg.size))
    }
}

/** Построитель TCP-ответов телефону: SYN-ACK / data / FIN / RST с корректными чексуммами. */
object TcpReplyBuilder {
    fun synAck(flow: Ipv4Flow, isn: Long, peerSeq: Long, windowScale: Int = 7): ByteArray =
        buildTcp(flow, isn, peerSeq + 1, TcpParser.SYN or TcpParser.ACK, ByteArray(0), windowScale)

    fun data(flow: Ipv4Flow, seq: Long, ack: Long, payload: ByteArray): ByteArray =
        buildTcp(flow, seq, ack, TcpParser.ACK or (if (payload.isNotEmpty()) TcpParser.PSH else 0), payload, null)

    fun fin(flow: Ipv4Flow, seq: Long, ack: Long): ByteArray =
        buildTcp(flow, seq, ack, TcpParser.FIN or TcpParser.ACK, ByteArray(0), null)

    fun rst(flow: Ipv4Flow, seq: Long, ack: Long): ByteArray =
        buildTcp(flow, seq, ack, TcpParser.RST or TcpParser.ACK, ByteArray(0), null)

    private fun buildTcp(flow: Ipv4Flow, seq: Long, ack: Long, flags: Int, payload: ByteArray, wscale: Int?): ByteArray {
        // Ответ идёт в обратную сторону: src<->dst меняются местами.
        val srcIp = flow.dstAddr; val dstIp = flow.srcAddr
        val srcPort = flow.dstPort; val dstPort = flow.srcPort
        val opts = if (wscale != null) byteArrayOf(0x02, 0x04, 0x05, -76, 0x01, 0x03, 0x03, wscale.toByte(), 0x01, 0x01, 0x04, 0x02) else byteArrayOf()
        val tcpLen = 20 + opts.size + payload.size
        val tcp = ByteBuffer.allocate(tcpLen).order(ByteOrder.BIG_ENDIAN)
        tcp.putShort(srcPort.toShort()); tcp.putShort(dstPort.toShort())
        tcp.putInt(seq.toInt()); tcp.putInt(ack.toInt())
        tcp.put(((5 + opts.size / 4) shl 4).toByte()); tcp.put(flags.toByte())
        tcp.putShort(65535.toShort()); tcp.putShort(0); tcp.putShort(0)
        tcp.put(opts); tcp.put(payload)
        val tcpArr = tcp.array()
        val pseudo = ByteBuffer.allocate(12 + tcpLen).order(ByteOrder.BIG_ENDIAN)
        pseudo.putInt(srcIp); pseudo.putInt(dstIp)
        pseudo.put(0); pseudo.put(6); pseudo.putShort(tcpLen.toShort()); pseudo.put(tcpArr)
        val csum = checksum(pseudo.array())
        tcpArr[16] = (csum ushr 8).toByte(); tcpArr[17] = (csum and 0xFF).toByte()

        val ip = ByteBuffer.allocate(20 + tcpLen).order(ByteOrder.BIG_ENDIAN)
        ip.put(0x45.toByte()); ip.put(0); ip.putShort((20 + tcpLen).toShort())
        ip.putShort(0); ip.putShort(0); ip.put(64.toByte()); ip.put(6.toByte())
        ip.putShort(0); ip.putInt(srcIp); ip.putInt(dstIp); ip.put(tcpArr)
        val ipArr = ip.array()
        val icsum = checksum(ipArr.copyOfRange(0, 20))
        ipArr[10] = (icsum ushr 8).toByte(); ipArr[11] = (icsum and 0xFF).toByte()
        return ipArr
    }

    internal fun checksum(data: ByteArray): Int {
        var sum = 0L
        var i = 0
        while (i + 1 < data.size) {
            sum += (((data[i].toInt() and 0xFF) shl 8) or (data[i + 1].toInt() and 0xFF))
            if (sum > 0xFFFF) sum = (sum and 0xFFFF) + (sum ushr 16)
            i += 2
        }
        if (i < data.size) {
            sum += ((data[i].toInt() and 0xFF) shl 8)
            if (sum > 0xFFFF) sum = (sum and 0xFFFF) + (sum ushr 16)
        }
        return (sum.inv() and 0xFFFF).toInt()
    }
}

// ---------- UDP ----------

data class ParsedUdpDatagram(val srcPort: Int, val dstPort: Int, val payload: ByteArray)

object UdpParser {
    fun parse(dgram: ByteArray): ParsedUdpDatagram {
        require(dgram.size >= 8) { "udp truncated" }
        val src = Ipv4Parser.u16(dgram, 0); val dst = Ipv4Parser.u16(dgram, 2)
        val len = Ipv4Parser.u16(dgram, 4)
        require(len >= 8 && len <= dgram.size) { "udp bad length" }
        return ParsedUdpDatagram(src, dst, dgram.copyOfRange(8, len))
    }

    /** Собирает IPv4+UDP ответ телефону (для DNS relay). */
    fun buildReply(flow: Ipv4Flow, payload: ByteArray): ByteArray {
        val srcIp = flow.dstAddr; val dstIp = flow.srcAddr
        val udpLen = 8 + payload.size
        val udp = ByteBuffer.allocate(udpLen).order(ByteOrder.BIG_ENDIAN)
        udp.putShort(flow.dstPort.toShort()); udp.putShort(flow.srcPort.toShort())
        udp.putShort(udpLen.toShort()); udp.putShort(0); udp.put(payload)
        val udpArr = udp.array()
        val pseudo = ByteBuffer.allocate(12 + udpLen).order(ByteOrder.BIG_ENDIAN)
        pseudo.putInt(srcIp); pseudo.putInt(dstIp)
        pseudo.put(0); pseudo.put(17); pseudo.putShort(udpLen.toShort()); pseudo.put(udpArr)
        val csum = TcpReplyBuilder.checksum(pseudo.array())
        if (csum != 0) { udpArr[6] = (csum ushr 8).toByte(); udpArr[7] = (csum and 0xFF).toByte() }
        val ip = ByteBuffer.allocate(20 + udpLen).order(ByteOrder.BIG_ENDIAN)
        ip.put(0x45.toByte()); ip.put(0); ip.putShort((20 + udpLen).toShort())
        ip.putShort(0); ip.putShort(0); ip.put(64.toByte()); ip.put(17.toByte())
        ip.putShort(0); ip.putInt(srcIp); ip.putInt(dstIp); ip.put(udpArr)
        val ipArr = ip.array()
        val icsum = TcpReplyBuilder.checksum(ipArr.copyOfRange(0, 20))
        ipArr[10] = (icsum ushr 8).toByte(); ipArr[11] = (icsum and 0xFF).toByte()
        return ipArr
    }
}
