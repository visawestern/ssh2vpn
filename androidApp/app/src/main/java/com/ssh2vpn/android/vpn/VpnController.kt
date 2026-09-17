package com.ssh2vpn.android.vpn

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.VpnService
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * Контроллер VPN-разрешения и жизненного цикла.
 * prepare() -> старт сервиса -> фазы из SshVpnService.
 */
class VpnController(private val ctx: Context) {
    sealed interface Prep { object Ready : Prep; class NeedConsent(val intent: Intent) : Prep }

    fun checkPrepare(): Prep {
        val p = VpnService.prepare(ctx)
        return if (p == null) Prep.Ready else Prep.NeedConsent(p)
    }

    fun start(serverId: String) = SshVpnService.startCmd(ctx, serverId)
    fun stop() = SshVpnService.stopCmd(ctx)

    companion object {
        const val REQUEST_VPN = 1001
        fun onConsentResult(activity: Activity, resultCode: Int, serverId: String?, start: (String) -> Unit) {
            if (resultCode == Activity.RESULT_OK && serverId != null) start(serverId)
        }
    }
}
