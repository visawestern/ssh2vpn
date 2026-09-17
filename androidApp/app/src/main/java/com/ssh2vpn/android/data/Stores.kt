package com.ssh2vpn.android.data

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.longPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

private val Context.quotaMeta by preferencesDataStore("quota")

class QuotaStore(private val ctx: Context) {
    private val kLedger = stringPreferencesKey("ledger")
    private val json = Json { ignoreUnknownKeys = true }

    @kotlinx.serialization.Serializable
    private data class Dto(val unlimited: Boolean = false, val expiresAt: Long? = null, val lastAdViewAt: Long? = null)

    suspend fun load(): QuotaLedger {
        // Лежер дублируем и в EncryptedSharedPreferences (защита от сброса DataStore),
        // источник правды — зашифрованное хранилище.
        return try {
            val raw = vault().getString("ledger", null) ?: return QuotaLedger()
            val d = json.decodeFromString<Dto>(raw)
            QuotaLedger(d.unlimited, d.expiresAt, d.lastAdViewAt)
        } catch (_: Exception) { QuotaLedger() }
    }

    suspend fun save(l: QuotaLedger) {
        vault().edit().putString("ledger", json.encodeToString(Dto(l.unlimited, l.expiresAt, l.lastAdViewAt))).apply()
        ctx.quotaMeta.edit { it.set(kLedger, l.remainingSec().toString()) }
    }

    private fun vault(): android.content.SharedPreferences {
        val mk = MasterKey.Builder(ctx).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build()
        return EncryptedSharedPreferences.create(
            ctx, "quota_secrets", mk,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )
    }
}

class SettingsStore(private val ctx: Context) {
    private val k = stringPreferencesKey("settings")
    private val json = Json { ignoreUnknownKeys = true }
    suspend fun load(): AppSettings {
        return try {
            val raw = ctx.quotaMeta.data.map { it[k] }.first() ?: return AppSettings()
            json.decodeFromString(raw)
        } catch (_: Exception) { AppSettings() }
    }
    suspend fun save(s: AppSettings) {
        // protocol всегда нормализуем к SSH2 (как в iOS: мёртвый выбор не переживает персист).
        ctx.quotaMeta.edit { it.set(k, json.encodeToString(s.copy(protocolName = "SSH2"))) }
    }
}
