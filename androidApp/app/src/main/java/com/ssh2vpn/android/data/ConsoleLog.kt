package com.ssh2vpn.android.data

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Санитизированный консольный лог — порт ConsoleLogStore + ConsoleLogSanitizer.
 * Dual-write в logcat (аналог NSLog/sysdiagnose) + дедуп повторов.
 */
object ConsoleLog {
    private val fmt = SimpleDateFormat("HH:mm:ss", Locale.US)
    data class Line(val time: String, val level: String, val tag: String, val message: String, val times: Int = 1)
    private val _lines = MutableStateFlow<List<Line>>(emptyList())
    val lines: StateFlow<List<Line>> = _lines
    var enabled: Boolean = false

    private val pemRe = Regex("(-----BEGIN [A-Z0-9 ]+PRIVATE KEY-----)[\\s\\S]*?(-----END [A-Z0-9 ]+PRIVATE KEY-----)")
    private val pwRes = listOf(
        Regex("""(?i)(password|passwd|pwd|auth|secret)\s*[:=]\s*["']?([^"'\s,;]+)["']?"""),
        Regex(""""(?i)(password|passwd|pwd|secret)"\s*:\s*"([^"]+)""""),
        Regex("""(?<=\s-P\s)([^\s]+)""")
    )

    /** Порт ConsoleLogSanitizer.sanitize 1-в-1 (флаги hasPassword=true не трутся). */
    fun sanitize(m: String): String {
        if (m.isEmpty()) return m
        var s = pemRe.replace(m, "$1\n[PRIVATE_KEY_REDACTED]\n$2")
        for (re in pwRes) {
            s = re.replace(s) { mr ->
                val groups = mr.groupValues
                val target = if (groups.size > 2) 2 else 1
                val captured = groups.getOrNull(target).orEmpty()
                if (captured.lowercase() == "true" || captured.lowercase() == "false") mr.value
                else mr.value.replaceRange(mr.groups[target]!!.range, "***REDACTED***")
            }
        }
        return s.take(2000)
    }

    @Synchronized
    fun log(level: String, tag: String, message: String) {
        val clean = sanitize(message)
        // Dual-write в logcat — видно в adb logcat / bugreport, как NSLog в sysdiagnose.
        try {
            val pri = when (level.lowercase()) {
                "err", "error" -> android.util.Log.ERROR
                "warn", "warning" -> android.util.Log.WARN
                "ok", "success" -> android.util.Log.INFO
                else -> android.util.Log.DEBUG
            }
            android.util.Log.println(pri, "SSH2VPN/$tag", clean.take(4000))
        } catch (_: Exception) {}
        val line = Line(fmt.format(Date()), level.uppercase(), tag, clean)
        val cur = _lines.value
        // Dedupe: тот же tag+message в окне 5с — счётчик ×N вместо новой строки.
        val last = cur.lastOrNull()
        _lines.value = if (last != null && last.tag == line.tag && last.message == line.message) {
            cur.dropLast(1) + last.copy(times = last.times + 1)
        } else {
            (cur + line).takeLast(2000)
        }
    }

    fun export(): String = _lines.value.joinToString("\n") {
        "[${it.time}] ${it.level}/${it.tag}: ${it.message}" + if (it.times > 1) " (×${it.times})" else ""
    }
    fun clear() { _lines.value = emptyList() }
}
