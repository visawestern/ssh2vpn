# SSH2VPN Android — правила обфускации минимальны: JSch и BouncyCastle не обфусцировать.
-keep class com.jcraft.jsch.** { *; }
-keep class org.bouncycastle.** { *; }
