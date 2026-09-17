package com.ssh2vpn.android.ui

import android.app.Activity
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.ssh2vpn.android.R
import com.ssh2vpn.android.ads.RewardedOutcome
import com.ssh2vpn.android.core.CountryCentroids
import com.ssh2vpn.android.core.MapProjection
import com.ssh2vpn.android.vpn.SshVpnService
import kotlinx.coroutines.launch

/** Главный экран Connect — зеркало iOS Connect tab: карта, кнопка, сервер, статы, квота. */
@Composable
fun ScreenConnect(
    vm: AppViewModel,
    onConnect: (String) -> Unit,
    onServers: () -> Unit,
    onSettings: () -> Unit,
    onDiag: () -> Unit,
    onConsole: () -> Unit,
    onPaywall: () -> Unit
) {
    val ctx = LocalContext.current
    val activity = ctx as? Activity
    val scope = rememberCoroutineScope()
    val rows by vm.rows.collectAsState()
    val selectedId by vm.selectedId.collectAsState()
    val phase by vm.phase.collectAsState()
    val stats by vm.stats.collectAsState()
    val quota by vm.quota.collectAsState()
    val lastError by vm.lastError.collectAsState()
    val unlimited by vm.store.unlimited.collectAsState()
    val prices by vm.store.prices.collectAsState()
    val adReady by vm.ads.adReady.collectAsState()
    val cooldown by vm.ads.canEarnInSec.collectAsState()
    val playing by vm.ads.playing.collectAsState()
    var adNotice by remember { mutableStateOf<String?>(null) }

    val selected = rows.firstOrNull { it.profile.id == selectedId } ?: rows.firstOrNull()
    val connected = phase == "ready" || phase == "transport"

    LazyColumn(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            Text(
                if (connected) "● ${stringResource(R.string.connected)}" else "● ${stringResource(R.string.disconnected)}",
                style = MaterialTheme.typography.titleMedium,
                color = if (connected) Octo.Prim100 else Octo.Gray60
            )
        }
        item {
            // Карта мира с точками серверов — тот же ассет 1920x954 и та же проекция.
            Card(Modifier.fillMaxWidth()) {
                BoxWithConstraints(Modifier.fillMaxWidth().height(190.dp)) {
                    Image(
                        painterResource(R.drawable.world_map), contentDescription = null,
                        modifier = Modifier.fillMaxSize(), contentScale = ContentScale.FillBounds
                    )
                    Canvas(Modifier.fillMaxSize()) {
                        val w = size.width; val h = size.height
                        for (r in rows) {
                            val cc = r.countryCode ?: continue
                            val centroid = CountryCentroids.coordinate(cc) ?: continue
                            val (x, y) = MapProjection.viewPoint(
                                centroid.second, centroid.first, w.toDouble(), h.toDouble(), cc
                            )
                            val sel = r.profile.id == selected?.profile?.id
                            drawCircle(
                                color = if (sel) Color(0xFF3CC083) else Color(0xFF4575A0),
                                radius = if (sel) 9f else 6f,
                                center = Offset(x.toFloat(), y.toFloat())
                            )
                        }
                    }
                }
            }
        }
        item {
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        selected?.let { "${it.flag} ${it.profile.displayAddress}" }
                            ?: stringResource(R.string.no_server),
                        style = MaterialTheme.typography.titleLarge
                    )
                    selected?.let {
                        Text(
                            "${stringResource(R.string.country)}: ${it.countryCode ?: "—"}   " +
                                "${stringResource(R.string.ping)}: ${it.pingMs?.let { m -> "$m ms" } ?: "…"}",
                            style = MaterialTheme.typography.bodySmall
                        )
                    }
                    if (selected == null) {
                        Button(onClick = onServers, modifier = Modifier.fillMaxWidth()) {
                            Text(stringResource(R.string.add_server))
                        }
                    } else if (!connected) {
                        Button(onClick = { onConnect(selected.profile.id) }, modifier = Modifier.fillMaxWidth()) {
                            Text(stringResource(R.string.connect).uppercase())
                        }
                    } else {
                        Button(
                            onClick = { com.ssh2vpn.android.vpn.VpnController(ctx).stop() },
                            modifier = Modifier.fillMaxWidth()
                        ) { Text(stringResource(R.string.disconnect).uppercase()) }
                    }
                    lastError?.let { Text("${stringResource(R.string.error)}: $it", color = MaterialTheme.colorScheme.error) }
                }
            }
        }
        item {
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(12.dp)) {
                    Text("↑ ${fmtBytes(stats.upBytes)}   ↓ ${fmtBytes(stats.downBytes)}")
                    Text("${stringResource(R.string.diag_sshconnections)}: ${stats.poolConns}   " +
                        "${stringResource(R.string.diag_active_flows)}: ${stats.flows} (${stats.channels})")
                    if (stats.egress.isNotBlank()) Text(stats.egress, style = MaterialTheme.typography.bodySmall)
                }
            }
        }
        item {
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (unlimited || quota.unlimited) {
                        Text("♾ ${stringResource(R.string.unlimited_badge)}")
                    } else {
                        val rem = quota.remainingSec()
                        Text("${stringResource(R.string.free_time_left)}: ${rem / 3600}ч ${(rem % 3600) / 60}м")
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            OutlinedButton(
                                onClick = {
                                    if (activity != null) vm.ads.show(activity, connected) { oc ->
                                        adNotice = when (oc) {
                                            RewardedOutcome.EARNED -> null
                                            RewardedOutcome.NO_FILL -> ctx.getString(R.string.ad_no_fill_short)
                                            RewardedOutcome.DISMISSED_EARLY -> ctx.getString(R.string.ad_reward_not_credited)
                                        }
                                        vm.refreshAsync()
                                    }
                                },
                                enabled = !playing && !connected && cooldown <= 0
                            ) {
                                Text(if (playing) "…" else stringResource(R.string.watch_ad_plus3h))
                            }
                            Button(onClick = onPaywall) {
                                Text("${stringResource(R.string.buy_unlimited)} (${prices.values.firstOrNull { it.isNotBlank() && it != "…" } ?: "…"})")
                            }
                        }
                        if (cooldown > 0) Text("${cooldown / 60}м", style = MaterialTheme.typography.bodySmall)
                        adNotice?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
                    }
                }
            }
        }
        item {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
                OutlinedButton(onClick = onServers) { Text(stringResource(R.string.locations)) }
                OutlinedButton(onClick = onSettings) { Text(stringResource(R.string.settings)) }
            }
            Spacer(Modifier.height(4.dp))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
                OutlinedButton(onClick = onDiag) { Text(stringResource(R.string.diagnostics)) }
                OutlinedButton(onClick = onConsole) { Text(stringResource(R.string.console)) }
            }
            Spacer(Modifier.height(4.dp))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) {
                OutlinedButton(onClick = { scope.launch { vm.refreshAsync() } }) { Text("⟳") }
            }
        }
    }
}

internal fun fmtBytes(n: Long): String = when {
    n < 1024 -> "$n Б"
    n < 1024 * 1024 -> "%.1f КБ".format(n / 1024.0)
    n < 1024 * 1024 * 1024 -> "%.1f МБ".format(n / 1024.0 / 1024.0)
    else -> "%.2f ГБ".format(n / 1024.0 / 1024.0 / 1024.0)
}

/** Диагностика — живые фазы/счётчики/ошибки/egress, зеркало iOS Diagnostics. */
@Composable
fun ScreenDiagnostics(vm: AppViewModel, onBack: () -> Unit) {
    val phase by SshVpnService.phase.collectAsState()
    val stats by SshVpnService.stats.collectAsState()
    val lastError by SshVpnService.lastError.collectAsState()
    val lastCode by vm.lastErrorCode.collectAsState()
    androidx.compose.foundation.lazy.LazyColumn(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedButton(onClick = onBack) { Text("‹ ${stringResource(R.string.cancel)}") }
                Spacer(Modifier.padding(4.dp))
                Text(stringResource(R.string.diagnostics_title), style = MaterialTheme.typography.headlineSmall)
            }
        }
        item {
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("${stringResource(R.string.status)}: $phase")
                    Text("${stringResource(R.string.diag_stop_reason)}: ${stats.stopReason}")
                    Text("${stringResource(R.string.diag_sshconnections)}: ${stats.poolConns}")
                    Text("${stringResource(R.string.diag_active_flows)}: ${stats.flows} (${stats.channels})")
                    Text("${stringResource(R.string.diag_downloaded)}: ${fmtBytes(stats.downBytes)}   ${stringResource(R.string.diag_uploaded)}: ${fmtBytes(stats.upBytes)}")
                    Text("${stringResource(R.string.diag_dns)}: upstream=${stats.dnsUpstream}")
                    Text(stats.protoSplit, style = MaterialTheme.typography.bodySmall)
                    if (stats.egress.isNotBlank()) Text(stats.egress, style = MaterialTheme.typography.bodySmall)
                    lastError?.let {
                        Text("${stringResource(R.string.diag_last_error)}: $it", color = MaterialTheme.colorScheme.error)
                        lastCode?.let { c -> Text("code: $c", style = MaterialTheme.typography.bodySmall) }
                    }
                }
            }
        }
        item {
            Text(stringResource(R.string.ssh_connection_failed), style = MaterialTheme.typography.bodySmall)
        }
    }
}

/** Консоль — санитизированный лог с экспортом. */
@Composable
fun ScreenConsole(onBack: () -> Unit) {
    val ctx = LocalContext.current
    val lines by com.ssh2vpn.android.data.ConsoleLog.lines.collectAsState()
    Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedButton(onClick = onBack) { Text("‹ ${stringResource(R.string.cancel)}") }
            Spacer(Modifier.padding(4.dp))
            Text(stringResource(R.string.console), style = MaterialTheme.typography.headlineSmall)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = {
                val send = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
                    type = "text/plain"
                    putExtra(android.content.Intent.EXTRA_TEXT, com.ssh2vpn.android.data.ConsoleLog.export())
                }
                ctx.startActivity(android.content.Intent.createChooser(send, "log"))
            }) { Text(stringResource(R.string.log_export)) }
            OutlinedButton(onClick = { com.ssh2vpn.android.data.ConsoleLog.clear() }) { Text(stringResource(R.string.log_clear)) }
        }
        androidx.compose.foundation.lazy.LazyColumn(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            items(lines.takeLast(300)) { l ->
                Text(
                    "[${l.time}] ${l.level}/${l.tag}: ${l.message}" + if (l.times > 1) " (×${l.times})" else "",
                    style = MaterialTheme.typography.bodySmall
                )
                androidx.compose.material3.Divider()
            }
        }
    }
}
