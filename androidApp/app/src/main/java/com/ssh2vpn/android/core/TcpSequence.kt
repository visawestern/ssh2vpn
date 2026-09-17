package com.ssh2vpn.android.core

/** Арифметика TCP sequence numbers — порт TCPSequence.swift 1-в-1. */
object TcpSequence {
    fun greaterThan(a: Long, b: Long): Boolean {
        val au = a and 0xFFFFFFFFL; val bu = b and 0xFFFFFFFFL
        return au != bu && ((au - bu) and 0xFFFFFFFFL) < 0x80000000L
    }
    /** Дистанция from -> to в uint32-кольце (знаковая: назад = отрицательная). */
    fun distance(from: Long, to: Long): Long {
        val d = ((to - from) and 0xFFFFFFFFL)
        return if (d >= 0x80000000L) d - 0x100000000L else d
    }
}
