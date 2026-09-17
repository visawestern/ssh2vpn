package com.ssh2vpn.android.ssh

import android.util.Base64
import com.jcraft.jsch.HostKey
import com.jcraft.jsch.HostKeyRepository
import java.security.MessageDigest

/**
 * Host-key pinning — зеркало iOS (host-key pinning обязателен).
 * Первый успешный тест сохраняет ключ; дальше любое несовпадение = отказ
 * с человеческим текстом (host key mismatch), а не тихое доверие.
 */
class PinnedHostKeyRepository(
    private var pinned: String?,
    private val onMismatch: (expected: String, got: String) -> Unit = { _, _ -> }
) : HostKeyRepository {

    fun pinnedKey(): String? = pinned
    fun pin(key: String) { pinned = key }

    override fun check(host: String?, key: ByteArray?): Int {
        if (key == null) return HostKeyRepository.NOT_INCLUDED
        val got = "SHA256:" + Base64.encodeToString(sha256(key), Base64.NO_WRAP)
        val exp = pinned
        if (exp == null) return HostKeyRepository.OK // первичное доверие: вызовет add() ниже
        if (exp == got || exp == Base64.encodeToString(key, Base64.NO_WRAP)) return HostKeyRepository.OK
        onMismatch(exp, got)
        return HostKeyRepository.NOT_INCLUDED
    }

    override fun add(hostkey: HostKey?, ui: com.jcraft.jsch.UserInfo?) {
        // JSch вызывает add при первом подключении (StrictHostKeyChecking=no):
        // фиксируем ключ как pinned. HostKey.key — base64 тела ключа.
        if (pinned == null && hostkey != null) {
            val raw = try {
                Base64.decode(hostkey.key, Base64.DEFAULT)
            } catch (_: Exception) { return }
            pinned = "SHA256:" + Base64.encodeToString(sha256(raw), Base64.NO_WRAP)
        }
    }

    override fun remove(host: String?, type: String?) {}
    override fun remove(host: String?, type: String?, key: ByteArray?) {}
    override fun getKnownHostsRepositoryID(): String = "pinned"
    override fun getHostKey(): Array<HostKey> = emptyArray()
    override fun getHostKey(host: String?, type: String?): Array<HostKey> = emptyArray()

    private fun sha256(b: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(b)

    companion object {
        fun fingerprintSha256(rawKeyBase64: String): String? = try {
            val raw = Base64.decode(rawKeyBase64, Base64.DEFAULT)
            "SHA256:" + Base64.encodeToString(MessageDigest.getInstance("SHA-256").digest(raw), Base64.NO_WRAP)
        } catch (_: Exception) { null }
    }
}
