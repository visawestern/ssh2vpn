package com.ssh2vpn.android.core

/** Порт PingBudget.swift: не более maxEvents декоративных пингов за window. */
class PingBudget(private val maxEvents: Int = 4, private val windowMs: Long = 30_000) {
    private val stamps = ArrayDeque<Long>()
    @Synchronized
    fun allow(now: Long = System.currentTimeMillis()): Boolean {
        while (stamps.isNotEmpty() && stamps.first() <= now - windowMs) stamps.removeFirst()
        if (stamps.size >= maxEvents) return false
        stamps.addLast(now)
        return true
    }
}

/** Порт RetryBudget.swift: опрос с лимитом попыток (по умолч. 5с × 24 = 2 мин). */
class RetryBudget(val maxAttempts: Int = 24, val intervalMs: Long = 5_000) {
    var used: Int = 0; private set
    val remaining: Int get() = maxOf(0, maxAttempts - used)
    fun consume(): Boolean {
        if (used >= maxAttempts) return false
        used++
        return true
    }
}

/** Порт ConnectionBreaker.swift: рубильник шторма коннектов (дефолт 10). */
class ConnectionBreaker(val maxConsecutiveFailures: Int = 10) {
    var consecutiveFailures: Int = 0; private set
    var tripped: Boolean = false; private set
    /** true ровно один раз — на провале, который выбил рубильник. */
    fun recordFailure(): Boolean {
        consecutiveFailures++
        if (!tripped && consecutiveFailures >= maxConsecutiveFailures) {
            tripped = true
            return true
        }
        return false
    }
    fun reset() { consecutiveFailures = 0; tripped = false }
}
