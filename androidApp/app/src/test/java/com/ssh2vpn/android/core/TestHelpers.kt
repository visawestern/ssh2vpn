package com.ssh2vpn.android.core

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Тестовые хелперы: сборка SYN-пакетов и фейковая фабрика каналов. */
class FakeTcpFactory : RelayChannelFactory {
    val opened = mutableListOf<RelayFlow>()
    private val sent = mutableMapOf<RelayFlow, MutableList<ByteArray>>()
    override fun open(flow: RelayFlow, onData: (ByteArray) -> Unit, onClosed: () -> Unit): RelayChannel {
        opened.add(flow); sent[flow] = mutableListOf()
        return object : RelayChannel {
            override fun send(data: ByteArray) { sent[flow]!!.add(data) }
            override fun close() {}
        }
    }
    fun sentBytes(): Int = sent.values.flatten().sumOf { it.size }
}

class SeqIsn(private var v: Long) : IsnGenerator {
    override fun next(): Long = v++
}

fun ip4(a: Int, b: Int, c: Int, d: Int): Int = (a shl 24) or (b shl 16) or (c shl 8) or d

fun ip4str(ip: Int): String =
    "${(ip ushr 24) and 0xFF}.${(ip ushr 16) and 0xFF}.${(ip ushr 8) and 0xFF}.${ip and 0xFF}"

fun buildSyn(
    srcIp: String, srcPort: Int, dstIp: String, dstPort: Int,
    seq: Long, ack: Long = 0, flags: Int = TcpParser.SYN, payload: ByteArray = ByteArray(0)
): ByteArray {
    fun toInt(s: String): Int {
        val p = s.split(".")
        return (p[0].toInt() shl 24) or (p[1].toInt() shl 16) or (p[2].toInt() shl 8) or p[3].toInt()
    }
    val sIp = toInt(srcIp); val dIp = toInt(dstIp)
    val tcp = ByteBuffer.allocate(20 + payload.size).order(ByteOrder.BIG_ENDIAN)
    tcp.putShort(srcPort.toShort()); tcp.putShort(dstPort.toShort())
    tcp.putInt(seq.toInt()); tcp.putInt(ack.toInt())
    tcp.put(0x50.toByte()); tcp.put(flags.toByte())
    tcp.putShort(65535.toShort()); tcp.putShort(0); tcp.putShort(0)
    tcp.put(payload)
    val ta = tcp.array()
    val pseudo = ByteBuffer.allocate(12 + ta.size).order(ByteOrder.BIG_ENDIAN)
    pseudo.putInt(sIp); pseudo.putInt(dIp)
    pseudo.put(0); pseudo.put(6); pseudo.putShort(ta.size.toShort()); pseudo.put(ta)
    val cs = TcpReplyBuilder.checksum(pseudo.array())
    ta[16] = (cs ushr 8).toByte(); ta[17] = (cs and 0xFF).toByte()
    val ip = ByteBuffer.allocate(20 + ta.size).order(ByteOrder.BIG_ENDIAN)
    ip.put(0x45.toByte()); ip.put(0); ip.putShort((20 + ta.size).toShort())
    ip.putShort(0); ip.putShort(0); ip.put(64.toByte()); ip.put(6.toByte())
    ip.putShort(0); ip.putInt(sIp); ip.putInt(dIp); ip.put(ta)
    val ia = ip.array()
    val ics = TcpReplyBuilder.checksum(ia.copyOfRange(0, 20))
    ia[10] = (ics ushr 8).toByte(); ia[11] = (ics and 0xFF).toByte()
    return ia
}

fun parseReplyTcp(pkt: ByteArray): ParsedTcpSegment {
    val iph = (pkt[0].toInt() and 0x0F) * 4
    return TcpParser.parse(pkt.copyOfRange(iph, pkt.size))
}
