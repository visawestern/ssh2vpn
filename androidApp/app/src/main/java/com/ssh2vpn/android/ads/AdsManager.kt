package com.ssh2vpn.android.ads

import android.app.Activity
import com.google.android.gms.ads.AdRequest
import com.google.android.gms.ads.FullScreenContentCallback
import com.google.android.gms.ads.LoadAdError
import com.google.android.gms.ads.MobileAds
import com.google.android.gms.ads.OnUserEarnedRewardListener
import com.google.android.gms.ads.rewarded.RewardedAd
import com.google.android.gms.ads.rewarded.RewardedAdLoadCallback
import com.google.android.ump.ConsentRequestParameters
import com.google.android.ump.UserMessagingPlatform
import com.ssh2vpn.android.data.ConsoleLog
import com.ssh2vpn.android.data.QuotaStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

/**
 * Конфиг рекламы — зеркало AdsConfig (iOS).
 * ВНИМАНИЕ: unit'ы ниже — тестовые Google. Боевые Android-unit'ы заводятся
 * в том же AdMob-аккаунте (отдельный App ID на платформу!) и вписываются сюда.
 */
object AdsConfig {
    const val APP_ID = "ca-app-pub-xxxxxxxxxxxxxxxx~yyyyyyyyyy" // TODO: picks from manifest
    const val REWARDED_UNIT_ID = "ca-app-pub-3940256099942544/5224354917" // TODO: боевой unit
    const val LOAD_TIMEOUT_MS = 20_000L
    /**
     * Заглушка rewarded: true = вместо AdMob показывается локальный диалог
     * «реклама» на 5 секунд и честно начисляется +3ч через тот же путь
     * (кулдаун 1ч, cap 12ч, first-use грант). Поставить false, когда будут
     * боевые unit'ы (см. P-43).
     */
    const val STUB_REWARDED = true
    const val STUB_SECONDS = 5
}

/** Исход rewarded-потока — порт RewardedOutcome (iOS). */
enum class RewardedOutcome { EARNED, NO_FILL, DISMISSED_EARLY }

/**
 * Rewarded free-tier — зеркало AdsManager (iOS):
 * +3ч за досмотр, не чаще 1 раза в час, потолок 12ч, таймаут загрузки 20с,
 * исходы earned/noFill/dismissedEarly. Показ ТОЛЬКО при выключенном VPN.
 * Порядок: UMP → MobileAds.start (ATT — только iOS).
 */
class AdsManager(private val ctx: android.content.Context, private val scope: CoroutineScope) {

    private val _canEarnIn = MutableStateFlow(0L)
    val canEarnInSec: StateFlow<Long> = _canEarnIn
    private val _ready = MutableStateFlow(false)
    val adReady: StateFlow<Boolean> = _ready
    private val _playing = MutableStateFlow(false)
    val playing: StateFlow<Boolean> = _playing

    private var ad: RewardedAd? = null

    fun initConsentAndAds(activity: Activity, done: () -> Unit = {}) {
        val params = ConsentRequestParameters.Builder().build()
        val consentInfo = UserMessagingPlatform.getConsentInformation(ctx)
        consentInfo.requestConsentInfoUpdate(
            activity, params,
            {
                UserMessagingPlatform.loadAndShowConsentFormIfRequired(activity) { _ ->
                    MobileAds.initialize(ctx) {}
                    scope.launch { load(); done() }
                }
            },
            {
                MobileAds.initialize(ctx) {}
                scope.launch { load(); done() }
            }
        )
    }

    /** Загрузка с таймаутом 20с (race guard как AdLoadBox в iOS). */
    suspend fun load(): Boolean {
        _ready.value = false
        val loaded = withTimeoutOrNull(AdsConfig.LOAD_TIMEOUT_MS) {
            suspendCancellableCoroutine<RewardedAd?> { cont ->
                var resumed = false
                RewardedAd.load(ctx, AdsConfig.REWARDED_UNIT_ID, AdRequest.Builder().build(),
                    object : RewardedAdLoadCallback() {
                        override fun onAdLoaded(a: RewardedAd) {
                            if (!resumed) { resumed = true; ad = a; cont.resume(a) }
                        }
                        override fun onAdFailedToLoad(e: LoadAdError) {
                            ConsoleLog.log("warn", "ADS", "rewarded load failed: ${e.message}")
                            if (!resumed) { resumed = true; cont.resume(null) }
                        }
                    })
            }
        }
        _ready.value = loaded != null
        return loaded != null
    }

    fun preload() {
        scope.launch { load() }
    }

    /**
     * Показать rewarded. vpnConnected обязан быть false (compliance §2.1).
     * Исход — через колбэк (earned начисляет +3ч).
     */
    fun show(activity: Activity, vpnConnected: Boolean, onOutcome: (RewardedOutcome) -> Unit) {
        if (vpnConnected) {
            ConsoleLog.log("warn", "ADS", "показ отклонён: VPN включён (compliance)")
            onOutcome(RewardedOutcome.NO_FILL); return
        }
        if (AdsConfig.STUB_REWARDED) {
            showStub(activity, onOutcome)
            return
        }
        val a = ad ?: run {
            scope.launch {
                val ok = load()
                scope.launch(Dispatchers.Main) {
                    if (!ok) onOutcome(RewardedOutcome.NO_FILL)
                    else show(activity, vpnConnected, onOutcome)
                }
            }
            return
        }
        var earned = false
        a.fullScreenContentCallback = object : FullScreenContentCallback() {
            override fun onAdDismissedFullScreenContent() {
                _playing.value = false
                ad = null
                preload()
                onOutcome(if (earned) RewardedOutcome.EARNED else RewardedOutcome.DISMISSED_EARLY)
            }
            override fun onAdFailedToShowFullScreenContent(e: com.google.android.gms.ads.AdError) {
                _playing.value = false
                ad = null
                preload()
                onOutcome(RewardedOutcome.NO_FILL)
            }
        }
        _playing.value = true
        _ready.value = false
        a.show(activity, OnUserEarnedRewardListener {
            earned = true
            creditEarned()
        })
    }

    /** Начисление +3ч — общий путь для боевого и стаб-показа. */
    private fun creditEarned() {
        scope.launch(Dispatchers.IO) {
            val q = QuotaStore(ctx)
            val cur = q.load()
            val base = if (cur.expiresAt == null && !cur.unlimited) cur.withInitialGrant() else cur
            val next = base.creditingAdView()
            if (next != null) {
                q.save(next)
                ConsoleLog.log("ok", "ADS", "начислено +3ч")
            } else if (base != cur) q.save(base)
            refreshCooldown()
        }
    }

    /**
     * Заглушка вместо AdMob: модальный диалог с обратным отсчётом.
     * Досмотрел — EARNED (+3ч), закрыл раньше — DISMISSED_EARLY (без начисления).
     */
    private fun showStub(activity: Activity, onOutcome: (RewardedOutcome) -> Unit) {
        if (activity.isFinishing) {
            onOutcome(RewardedOutcome.NO_FILL); return
        }
        _playing.value = true
        val main = android.os.Handler(android.os.Looper.getMainLooper())
        var left = AdsConfig.STUB_SECONDS
        var done = false
        val dlg = android.app.AlertDialog.Builder(activity)
            .setTitle("Реклама (заглушка)")
            .setMessage("До награды +3ч: $left…")
            .setCancelable(true)
            .create()
        fun finish(earned: Boolean) {
            if (done) return
            done = true
            main.removeCallbacksAndMessages(null)
            try { dlg.dismiss() } catch (_: Exception) {}
            _playing.value = false
            if (earned) {
                creditEarned()
                onOutcome(RewardedOutcome.EARNED)
            } else {
                onOutcome(RewardedOutcome.DISMISSED_EARLY)
            }
        }
        dlg.setOnCancelListener { finish(false) }
        dlg.setOnDismissListener { finish(false) }
        val tick = object : Runnable {
            override fun run() {
                if (done) return
                left--
                if (left <= 0) {
                    finish(true)
                    return
                }
                try { dlg.setMessage("До награды +3ч: $left…") } catch (_: Exception) {}
                main.postDelayed(this, 1000)
            }
        }
        try {
            dlg.show()
        } catch (_: Exception) {
            _playing.value = false
            onOutcome(RewardedOutcome.NO_FILL)
            return
        }
        main.postDelayed(tick, 1000)
    }

    suspend fun refreshCooldown() {
        val l = QuotaStore(ctx).load()
        val last = l.lastAdViewAt ?: run { _canEarnIn.value = 0; return }
        _canEarnIn.value = maxOf(0, 3600 - (System.currentTimeMillis() - last) / 1000)
    }
}
