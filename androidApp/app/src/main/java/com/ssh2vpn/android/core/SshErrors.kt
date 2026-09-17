package com.ssh2vpn.android.core

/**
 * Стабильные коды старта туннеля — порт stableStartError (PacketTunnelProvider).
 * FATAL — без авто-ретрая (иначе fail2ban-бан за шторм); transient — можно.
 */
sealed class SshStartError(val code: String, val fatal: Boolean, message: String) : Exception(message) {
    class AuthFailed(detail: String) : SshStartError(
        "authFailedExhausted", true,
        "Сервер отклонил учётные данные (неверный пароль/ключ или метод запрещён). Исправьте данные — повторы не помогут."
    )
    class HostKeyMismatch(val expected: String, val got: String) : SshStartError(
        "hostKeyMismatch", true,
        "Host key сервера отличается от записанного. Проверьте сервер или обновите ключ — повторы не помогут."
    )
    class ForwardingRefused(host: String, port: Int, detail: String) : SshStartError(
        "forwardingRefused", true,
        "Сервер запрещает TCP-форвардинг ($host:$port): $detail. Проверьте AllowTcpForwarding в sshd_config — повторы не помогут."
    )
    class EgressBlocked(tried: List<String>) : SshStartError(
        "egressBlocked", false,
        "Сервер форвардит, но не выходит в интернет (${tried.joinToString()})."
    )
    class Transient(detail: String) : SshStartError("transient", false, detail)
}

/** Вердикт post-connect self-test — порт TunnelSelfTest.swift. */
sealed class EgressVerdict {
    object ViaServer : EgressVerdict()
    data class Bypass(val observed: String) : EgressVerdict()
    data class Unparseable(val reason: String) : EgressVerdict()
    object UnknownExpected : EgressVerdict()
}

object EgressTest {
    fun normalizeIP(raw: String): String {
        var s = raw.trim().lowercase()
        if (s.startsWith("[") && s.endsWith("]") && s.length > 2) s = s.substring(1, s.length - 1)
        return s
    }
    fun evaluate(expected: String?, observed: String): EgressVerdict {
        if (expected == null || normalizeIP(expected).isEmpty()) return EgressVerdict.UnknownExpected
        val o = normalizeIP(observed)
        if (o.isEmpty()) return EgressVerdict.Unparseable("empty response")
        if (!isIPLiteral(o)) return EgressVerdict.Unparseable("not an IP literal")
        return if (o == normalizeIP(expected)) EgressVerdict.ViaServer else EgressVerdict.Bypass(o)
    }
    fun pickExpected(host: String, resolvedIPv4: List<String>): String? {
        val h = normalizeIP(host)
        if (isIPLiteral(h)) return h
        return resolvedIPv4.firstOrNull()?.let { normalizeIP(it) }
    }
    private fun isIPLiteral(s: String): Boolean {
        if (':' in s) return true
        val parts = s.split(".")
        if (parts.size != 4) return false
        return parts.all { p ->
            p.isNotEmpty() && p.length <= 3 && p.all { it.isDigit() } && (p.toIntOrNull() ?: -1) in 0..255
        }
    }
}
