package com.ssh2vpn.android.data

import android.content.Context
import androidx.appcompat.app.AppCompatDelegate
import androidx.core.os.LocaleListCompat
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

/** Порт AppLanguage + LanguageStore (iOS): 17 языков, флаги, порядок, пер-апп локаль. */
enum class AppLanguage(val tag: String, val title: String, val flag: String) {
    ENGLISH("en", "English", "🇬🇧"),
    SPANISH("es", "Español", "🇪🇸"),
    GERMAN("de", "Deutsch", "🇩🇪"),
    FRENCH("fr", "Français", "🇫🇷"),
    ITALIAN("it", "Italiano", "🇮🇹"),
    PORTUGUESE("pt-BR", "Português", "🇧🇷"),
    JAPANESE("ja", "日本語", "🇯🇵"),
    CHINESE("zh-Hans", "简体中文", "🇨🇳"),
    KOREAN("ko", "한국어", "🇰🇷"),
    ARABIC("ar", "العربية", "🇸🇦"),
    HINDI("hi", "हिन्दी", "🇮🇳"),
    THAI("th", "ไทย", "🇹🇭"),
    TURKISH("tr", "Türkçe", "🇹🇷"),
    POLISH("pl", "Polski", "🇵🇱"),
    DUTCH("nl", "Nederlands", "🇳🇱"),
    VIETNAMESE("vi", "Tiếng Việt", "🇻🇳"),
    RUSSIAN("ru", "Русский", "🇷🇺");

    companion object {
        fun of(tag: String?): AppLanguage? = values().firstOrNull { it.tag == tag }
        /** Порядок списка: язык устройства и страны — наверх, как в iOS. */
        fun ordered(deviceTag: String?, countryTag: String?): List<AppLanguage> {
            val rest = values().toMutableList()
            val top = mutableListOf<AppLanguage>()
            countryTag?.let { of(it) }?.let { if (rest.remove(it)) top.add(it) }
            deviceTag?.let { of(it.split("-").first()) }?.let { if (rest.remove(it)) top.add(it) }
            return top + rest
        }
    }
}

class LanguageStore(private val ctx: Context) {
    private val prefs = ctx.getSharedPreferences("lang", Context.MODE_PRIVATE)

    fun current(): AppLanguage? = AppLanguage.of(prefs.getString("selectedLanguage", null))

    fun apply(tag: String?) {
        prefs.edit().putString("selectedLanguage", tag).apply()
        AppCompatDelegate.setApplicationLocales(
            if (tag == null) LocaleListCompat.getEmptyLocaleList()
            else LocaleListCompat.forLanguageTags(tag.replace("zh-Hans", "zh-Hans"))
        )
    }

    fun applySaved() = apply(prefs.getString("selectedLanguage", null))

    val flow: Flow<AppLanguage?> = kotlinx.coroutines.flow.flow { emit(current()) }
}
