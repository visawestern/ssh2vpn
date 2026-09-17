package com.ssh2vpn.android.data

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

private val Context.store by preferencesDataStore("servers_meta")

/**
 * Хранилище серверов — зеркало TunnelServerStore:
 * публичные поля — DataStore, секреты (пароль/ключ) — ТОЛЬКО EncryptedSharedPreferences
 * (аналог iOS Keychain). Дедуп по host:port:username.
 */
class ServerStore(private val ctx: Context) {
    private val json = Json { ignoreUnknownKeys = true }
    private val metaSelected = stringPreferencesKey("selected")
    private val metaList = stringPreferencesKey("servers")
    private fun vault(): android.content.SharedPreferences {
        val mk = MasterKey.Builder(ctx).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build()
        return EncryptedSharedPreferences.create(
            ctx, "server_secrets", mk,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )
    }

    /** Атомарная запись меты (edit в 1.1.x — обычная лямбда с параметром it). */
    private suspend fun writeMeta(mut: (androidx.datastore.preferences.core.MutablePreferences) -> Unit) {
        ctx.store.edit { prefs -> mut(prefs) }
    }

    suspend fun loadAll(): List<ServerProfile> {
        val raw = ctx.store.data.map { it[metaList] }.first() ?: return emptyList()
        val list = try { json.decodeFromString<List<ServerProfile>>(raw) } catch (_: Exception) { emptyList() }
        val v = vault()
        // Гидрация флагов наличием секретов (секреты наружу не отдаём отдельно — только флаги).
        return list.map { p ->
            val hasPw = v.contains("pw:${p.id}")
            val hasKey = v.contains("key:${p.id}")
            p.copy(hasPassword = hasPw, hasPrivateKey = hasKey)
        }
    }

    suspend fun password(id: String): String? = vault().getString("pw:$id", null)
    suspend fun privateKey(id: String): String? = vault().getString("key:$id", null)

    suspend fun save(profile: ServerProfile, password: String?, privateKey: String?): Boolean {
        return try {
            val v = vault()
            // Не затираем недоступные секреты при редактировании с сохранением имеющихся.
            if (password != null) v.edit().putString("pw:${profile.id}", password).apply()
            if (privateKey != null) v.edit().putString("key:${profile.id}", privateKey).apply()
            val all = loadAll().toMutableList()
            val pub = profile.copy(
                hasPassword = password != null || v.contains("pw:${profile.id}"),
                hasPrivateKey = privateKey != null || v.contains("key:${profile.id}")
            )
            val i = all.indexOfFirst { it.id == profile.id }
            if (i >= 0) all[i] = pub else all.add(pub)
            writeMeta { it.set(metaList, json.encodeToString(all)) }
            true
        } catch (_: Exception) { false }
    }

    suspend fun delete(id: String) {
        vault().edit().remove("pw:$id").remove("key:$id").apply()
        val all = loadAll().filter { it.id != id }
        writeMeta { it.set(metaList, json.encodeToString(all)) }
        if (selectedId() == id) writeMeta { it.remove(metaSelected) }
    }

    suspend fun selectedId(): String? = ctx.store.data.map { it[metaSelected] }.first()
    suspend fun select(id: String) { writeMeta { it.set(metaSelected, id) } }

    suspend fun dedupe(): Int {
        val all = loadAll()
        val seen = mutableSetOf<String>()
        val keep = mutableListOf<ServerProfile>()
        var removed = 0
        for (p in all) {
            val k = "${p.host}:${p.port}:${p.username}"
            if (seen.add(k)) keep.add(p) else removed++
        }
        if (removed > 0) writeMeta { it.set(metaList, json.encodeToString(keep)) }
        return removed
    }
}
