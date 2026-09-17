// Top-level build file for the Android port of SSH2VPN.
// Same product, same relay architecture as iOS: only SSH direct-tcpip channels.
plugins {
    // Kotlin 2.0: compose compiler — отдельным Gradle-плагином (версия = версии Kotlin).
    id("com.android.application") version "8.5.2" apply false
    id("org.jetbrains.kotlin.android") version "2.0.20" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.0.20" apply false
    id("org.jetbrains.kotlin.plugin.serialization") version "2.0.20" apply false
}
