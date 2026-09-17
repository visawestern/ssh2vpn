package com.ssh2vpn.android.ssh

import android.util.Base64

/**
 * Парсинг Ed25519-ключей — зеркало SSHPrivateKey.swift:
 * поддерживается только НЕзашифрованный Ed25519 in-process;
 * зашифрованные и прочие алгоритмы отвергаются явной ошибкой.
 * В хранилище кладётся только нормализованный seed (32 байта, base64).
 */
object SshKeyParser {
    sealed class KeyError(message: String) : Exception(message) {
        object Encrypted : KeyError("Зашифрованные ключи пока не поддерживаются — снимите passphrase")
        object UnsupportedAlgorithm : KeyError("Поддерживается только Ed25519")
        object Malformed : KeyError("Ключ не распознан (ожидается OpenSSH Ed25519)")
    }

    /** Нормализует OpenSSH-приватный ключ к seed base64. Бросает KeyError иначе. */
    fun normalizeEd25519Seed(openSshPrivateKey: String): String {
        val text = openSshPrivateKey.trim()
        if (!text.contains("OPENSSH PRIVATE KEY")) throw KeyError.Malformed
        if (text.contains("ENCRYPTED") && !text.contains("none")) {
            // Точная проверка ниже по бинарю; эвристика для быстрого отказа.
        }
        val b64 = text.lines()
            .filter { !it.startsWith("-----") && it.isNotBlank() }
            .joinToString("")
        val raw = try { Base64.decode(b64, Base64.DEFAULT) } catch (_: Exception) { throw KeyError.Malformed }
        return parseOpenSsh(raw)
    }

    private fun parseOpenSsh(raw: ByteArray): String {
        var p = 0
        fun take(n: Int): ByteArray {
            if (p + n > raw.size) throw KeyError.Malformed
            return raw.copyOfRange(p, p + n).also { p += n }
        }
        fun takeString(): ByteArray {
            val len = take(4).let {
                ((it[0].toInt() and 0xFF) shl 24) or ((it[1].toInt() and 0xFF) shl 16) or
                    ((it[2].toInt() and 0xFF) shl 8) or (it[3].toInt() and 0xFF)
            }
            return take(len)
        }
        val magic = "openssh-key-v1\u0000".toByteArray(Charsets.US_ASCII)
        if (raw.size < magic.size || !raw.copyOfRange(0, magic.size).contentEquals(magic)) throw KeyError.Malformed
        p = magic.size
        val cipher = String(takeString(), Charsets.US_ASCII)
        if (cipher != "none") throw KeyError.Encrypted
        takeString() // kdfname
        takeString() // kdfoptions
        val nkeys = take(4).let {
            ((it[0].toInt() and 0xFF) shl 24) or ((it[1].toInt() and 0xFF) shl 16) or
                ((it[2].toInt() and 0xFF) shl 8) or (it[3].toInt() and 0xFF)
        }
        if (nkeys != 1) throw KeyError.Malformed
        takeString() // pubkey blob
        val priv = takeString()
        // priv: check1(4) check2(4) keytype(string) pub( string) priv_seed+pub(string) comment(string) pad
        var q = 0
        fun qTake(n: Int): ByteArray {
            if (q + n > priv.size) throw KeyError.Malformed
            return priv.copyOfRange(q, q + n).also { q += n }
        }
        fun qString(): ByteArray {
            val len = qTake(4).let {
                ((it[0].toInt() and 0xFF) shl 24) or ((it[1].toInt() and 0xFF) shl 16) or
                    ((it[2].toInt() and 0xFF) shl 8) or (it[3].toInt() and 0xFF)
            }
            return qTake(len)
        }
        qTake(8)
        val keytype = String(qString(), Charsets.US_ASCII)
        if (keytype != "ssh-ed25519") throw KeyError.UnsupportedAlgorithm
        qString() // pub
        val privBlob = qString() // 64 байта: seed(32) + pub(32)
        if (privBlob.size < 64) throw KeyError.Malformed
        val seed = privBlob.copyOfRange(0, 32)
        return Base64.encodeToString(seed, Base64.NO_WRAP)
    }
}
