package com.ssh2vpn.android.core

/** Порт TextInputSanitizer.swift (label): unsafe-скаляры, схлопывание пробелов, cap 40. */
object TextInput {
    const val LABEL_MAX_LENGTH = 40
    const val MAX_COMBINING_RUN = 6

    private fun isUnsafe(c: Int): Boolean = when (Character.getType(c)) {
        Character.CONTROL.toInt(), Character.FORMAT.toInt(),
        Character.LINE_SEPARATOR.toInt(), Character.PARAGRAPH_SEPARATOR.toInt(),
        Character.SURROGATE.toInt(), Character.PRIVATE_USE.toInt(),
        Character.UNASSIGNED.toInt() -> true
        else -> c in 0xFDD0..0xFDEF || (c and 0xFFFF) == 0xFFFE || (c and 0xFFFF) == 0xFFFF
    }

    private fun isCombining(c: Int): Boolean = when (Character.getType(c)) {
        Character.NON_SPACING_MARK.toInt(), Character.COMBINING_SPACING_MARK.toInt(),
        Character.ENCLOSING_MARK.toInt() -> true
        else -> false
    }

    fun sanitizeLabel(raw: String?, maxLength: Int = LABEL_MAX_LENGTH): String? {
        if (raw.isNullOrEmpty()) return null
        val out = StringBuilder()
        var pendingSpace = false
        var combiningRun = 0
        var i = 0
        while (i < raw.length) {
            val c = raw.codePointAt(i)
            i += Character.charCount(c)
            if (c == 0x20 || Character.isWhitespace(c)) { pendingSpace = true; continue }
            if (isUnsafe(c)) continue
            if (isCombining(c)) {
                combiningRun++
                if (combiningRun > MAX_COMBINING_RUN) continue
            } else combiningRun = 0
            if (pendingSpace && out.isNotEmpty()) out.append(' ')
            pendingSpace = false
            out.appendCodePoint(c)
        }
        // cap по графемам — приближение: по кодпоинтам
        var s = out.toString().trim()
        if (s.codePointCount(0, s.length) > maxLength) {
            var cut = s.length
            while (s.codePointCount(0, cut) > maxLength) cut -= Character.charCount(s.codePointBefore(cut))
            s = s.substring(0, cut).trim()
        }
        return s.ifEmpty { null }
    }
}

sealed class ProfileError(message: String) : Exception(message) {
    object EmptyHost : ProfileError("Укажите адрес сервера.")
    class InvalidHost(r: String) : ProfileError("Некорректный адрес: $r")
    object EmptyPort : ProfileError("Укажите порт.")
    object InvalidPortFormat : ProfileError("Порт — целое число.")
    class PortOutOfRange : ProfileError("Порт должен быть от 1 до 65535.")
    object EmptyUsername : ProfileError("Укажите username.")
    class InvalidUsername(r: String) : ProfileError("Некорректный username: $r")
    object MissingAuth : ProfileError("Нужен пароль или приватный ключ.")
    class BadKey(m: String) : ProfileError(m)
}

/** Порт ProfileValidator.swift (без UI). */
object ProfileValidator {
    fun validateHost(raw: String): String {
        val h = raw.trim()
        if (h.isEmpty()) throw ProfileError.EmptyHost
        if (h.length > 253) throw ProfileError.InvalidHost("слишком длинный")
        if (h.any { it.isWhitespace() || it == '/' || it == '@' || it == ':' && h.count { c -> c == ':' } > 7 }) {
            if (!h.startsWith("[") && h.contains(':') && !isIpv6ish(h)) throw ProfileError.InvalidHost("недопустимые символы")
        }
        return h.removeSurrounding("[", "]")
    }
    private fun isIpv6ish(h: String) = ':' in h && h.all { it.isDigit() || it in 'a'..'f' || it in 'A'..'F' || it == ':' || it == '.' }

    fun validatePort(raw: String): Int {
        val t = raw.trim()
        if (t.isEmpty()) throw ProfileError.EmptyPort
        val v = t.toIntOrNull() ?: throw ProfileError.InvalidPortFormat
        if (v !in 1..65535) throw ProfileError.PortOutOfRange()
        return v
    }
    fun validateUsername(raw: String): String {
        val u = raw.trim()
        if (u.isEmpty()) throw ProfileError.EmptyUsername
        if (u.length > 64 || u.any { it.isWhitespace() || it == '@' || it == ':' }) throw ProfileError.InvalidUsername("недопустимые символы")
        return u
    }
    fun requireAuth(password: String?, keyPem: String?) {
        if (password.isNullOrBlank() && keyPem.isNullOrBlank()) throw ProfileError.MissingAuth
    }
}

sealed class HostKeyError(message: String) : Exception(message) {
    object MultiLine : HostKeyError("Вставьте ровно одну строку ключа")
    object InvisibleScalars : HostKeyError("Ключ содержит невидимые/управляющие символы")
    object ExpectedFormat : HostKeyError("Ожидается ssh-ed25519 AAAA… (вывод ssh-keyscan), а не отпечаток")
    class UnknownType(t: String) : HostKeyError("Неизвестный тип «$t» — нужен вывод ssh-keyscan, не SHA256:…")
    object BadBase64 : HostKeyError("Данные ключа — не base64")
}

/** Порт HostKeyInvalidReason: валидация ручного ввода pinned host key. */
object HostKeyValidator {
    private val knownTypes = setOf(
        "ssh-rsa", "ssh-dss", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384",
        "ecdsa-sha2-nistp521", "ssh-ed25519", "sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com"
    )
    fun validate(raw: String): String {
        val t = raw.trim()
        if ('\n' in t) throw HostKeyError.MultiLine
        if (t.any { Character.getType(it.code) in setOf(
                Character.CONTROL.toInt(), Character.FORMAT.toInt(),
                Character.PRIVATE_USE.toInt(), Character.SURROGATE.toInt()) }) throw HostKeyError.InvisibleScalars
        val parts = t.split(Regex("\\s+"))
        if (parts.size < 2) throw HostKeyError.ExpectedFormat
        if (parts[0] !in knownTypes) throw HostKeyError.UnknownType(parts[0])
        try {
            android.util.Base64.decode(parts[1], android.util.Base64.DEFAULT)
        } catch (_: Exception) { throw HostKeyError.BadBase64 }
        return "${parts[0]} ${parts[1]}"
    }
}
