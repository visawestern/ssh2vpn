package com.ssh2vpn.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Divider
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.ssh2vpn.android.data.LanguageStore
import com.ssh2vpn.android.data.QuotaStore
import com.ssh2vpn.android.ui.AppViewModel
import com.ssh2vpn.android.ui.Octo
import com.ssh2vpn.android.ui.OctoTheme
import com.ssh2vpn.android.ui.ScreenAddServer
import com.ssh2vpn.android.ui.ScreenConnect
import com.ssh2vpn.android.ui.ScreenConsole
import com.ssh2vpn.android.ui.ScreenDiagnostics
import com.ssh2vpn.android.ui.ScreenDocs
import com.ssh2vpn.android.ui.ScreenLanguagePicker
import com.ssh2vpn.android.ui.ScreenPaywall
import com.ssh2vpn.android.ui.ScreenServers
import com.ssh2vpn.android.ui.ScreenSettings
import com.ssh2vpn.android.ui.ShowPrivacyGate
import com.ssh2vpn.android.ui.ShowFirstLaunchLanguage
import com.ssh2vpn.android.vpn.VpnController
import kotlinx.coroutines.launch

class SSH2VPNApp : android.app.Application() {
    val appScope = kotlinx.coroutines.CoroutineScope(
        kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.Main
    )
    override fun onCreate() {
        super.onCreate()
        try { LanguageStore(this).applySaved() } catch (_: Exception) {}
    }
}

class MainActivity : ComponentActivity() {
    private var pendingServerId: String? = null

    private val vpnConsent = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { r ->
        VpnController.onConsentResult(this, r.resultCode, pendingServerId) { id ->
            VpnController(this).start(id)
        }
        pendingServerId = null
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            OctoTheme {
                val ctx = LocalContext.current
                val app = ctx.applicationContext as SSH2VPNApp
                val vm = remember { AppViewModel(ctx.applicationContext) }
                // Инициируем UMP один раз.
                remember {
                    try {
                        vm.ads.initConsentAndAds(this@MainActivity) {}
                    } catch (_: Exception) {}
                    true
                }
                AppNav(vm, onConnect = { serverId ->
                    val scope = app.appScope
                    scope.launch {
                        val q = QuotaStore(this@MainActivity)
                        val cur = q.load()
                        if (cur.expiresAt == null && !cur.unlimited) q.save(cur.withInitialGrant())
                    }
                    when (val p = VpnController(this).checkPrepare()) {
                        is VpnController.Prep.Ready -> VpnController(this).start(serverId)
                        is VpnController.Prep.NeedConsent -> {
                            pendingServerId = serverId
                            vpnConsent.launch(p.intent)
                        }
                    }
                })
            }
        }
    }
}

@Composable
fun AppNav(vm: AppViewModel, onConnect: (String) -> Unit) {
    val ctx = LocalContext.current
    val nav = rememberNavController()
    val backStack by nav.currentBackStackEntryAsState()
    val route = backStack?.destination?.route ?: "connect"
    var showAdd by remember { mutableStateOf(false) }
    val privacyAck by vm.privacyAck.collectAsState()
    val lang by remember { mutableStateOf(LanguageStore(ctx).current()) }
    var langDismissed by remember(lang) { mutableStateOf(lang != null) }
    val settings by vm.settings.collectAsState()

    if (!privacyAck) {
        ShowPrivacyGate(onAccept = { vm.ackPrivacy() })
        return
    }
    if (!langDismissed) {
        ShowFirstLaunchLanguage(vm, onDone = { langDismissed = true })
        return
    }

    Scaffold(
        bottomBar = {
            Column {
                Divider(color = Octo.Divider)
                Row(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceEvenly
                ) {
                    Tab("connect", R.string.connect, route, nav)
                    Tab("servers", R.string.locations, route, nav)
                    Tab("settings", R.string.settings, route, nav)
                }
            }
        },
        floatingActionButton = {
            // Плавающая кнопка консоли — только при включённом логировании (как в iOS).
            if (settings.enableLogging && route != "console") {
                FloatingActionButton(onClick = { nav.navigate("console") }) {
                    Text(">_")
                }
            }
        }
    ) { pad ->
        Box(Modifier.fillMaxSize().padding(pad)) {
            NavHost(nav, startDestination = "connect") {
                composable("connect") {
                    ScreenConnect(vm, onConnect,
                        onServers = { nav.navigate("servers") },
                        onSettings = { nav.navigate("settings") },
                        onDiag = { nav.navigate("diag") },
                        onConsole = { nav.navigate("console") },
                        onPaywall = { nav.navigate("paywall") })
                }
                composable("servers") { ScreenServers(vm, onAdd = { showAdd = true }, onBack = { nav.popBackStack() }) }
                composable("settings") {
                    ScreenSettings(vm, onBack = { nav.popBackStack() },
                        onLang = { nav.navigate("lang") }, onDocs = { nav.navigate("docs") })
                }
                composable("diag") { ScreenDiagnostics(vm, onBack = { nav.popBackStack() }) }
                composable("console") { ScreenConsole(onBack = { nav.popBackStack() }) }
                composable("paywall") { ScreenPaywall(vm, onBack = { nav.popBackStack() }) }
                composable("docs") { ScreenDocs(onBack = { nav.popBackStack() }) }
                composable("lang") { ScreenLanguagePicker(vm, onBack = { nav.popBackStack() }) }
            }
        }
    }
    if (showAdd) ScreenAddServer(vm, onDone = { showAdd = false })
}

/** Кастомный таббар — как OctohideTabBar в iOS (не системный NavigationBar). */
@Composable
private fun Tab(route: String, label: Int, current: String, nav: androidx.navigation.NavHostController) {
    val sel = current == route
    Column(
        Modifier.clickable {
            nav.navigate(route) { popUpTo("connect"); launchSingleTop = true }
        }.padding(vertical = 8.dp, horizontal = 20.dp),
        horizontalAlignment = androidx.compose.ui.Alignment.CenterHorizontally
    ) {
        Text(
            if (route == "connect") "⏻" else if (route == "servers") "🌍" else "⚙",
            color = if (sel) Octo.Prim100 else Octo.Gray60
        )
        Text(
            stringResource(label),
            style = MaterialTheme.typography.labelSmall,
            color = if (sel) Octo.Prim100 else Octo.Gray60
        )
    }
}
