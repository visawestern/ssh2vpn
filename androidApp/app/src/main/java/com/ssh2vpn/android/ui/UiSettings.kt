package com.ssh2vpn.android.ui

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.Checkbox
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.ssh2vpn.android.R
import com.ssh2vpn.android.core.DnsListCatalog
import com.ssh2vpn.android.core.DnsPresets
import com.ssh2vpn.android.core.HostsParser
import com.ssh2vpn.android.data.AppSettings
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Settings: Protocol / DNS (custom+пресеты+правила+списки) / Advanced / язык / доки. */
@Composable
fun ScreenSettings(vm: AppViewModel, onBack: () -> Unit, onLang: () -> Unit, onDocs: () -> Unit) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val settings by vm.settings.collectAsState()
    val subs by vm.subs.collectAsState()
    var dnsTab by remember { mutableStateOf(0) } // 0 custom+presets+rules, 1 lists
    var primary by remember(settings) { mutableStateOf(settings.primaryDns) }
    var secondary by remember(settings) { mutableStateOf(settings.secondaryDns) }
    var newDomain by remember { mutableStateOf("") }
    var newIp by remember { mutableStateOf("") }
    var newSub by remember { mutableStateOf(true) }
    var newKindBlock by remember { mutableStateOf(true) }
    var ruleErrKey by remember { mutableStateOf<String?>(null) }
    var importMsg by remember { mutableStateOf<String?>(null) }

    val importRules = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri: Uri? ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch(Dispatchers.IO) {
            try {
                val text = ctx.contentResolver.openInputStream(uri)?.use { it.bufferedReader().readText() }
                    ?: throw IllegalArgumentException("empty")
                if (text.length > 5_000_000) throw IllegalArgumentException("too large")
                val parsed = HostsParser.parse(text)
                val cur = vm.settings.value
                val rules = (cur.dnsRules +
                    parsed.blocked.map { com.ssh2vpn.android.data.DnsRuleDto(it, "block", "", true) } +
                    parsed.overrides.map { (d, ip) -> com.ssh2vpn.android.data.DnsRuleDto(d, "override", ip, true) })
                    .distinctBy { it.domain to it.kind }
                vm.saveSettings(cur.copy(dnsRules = rules))
                withContext(Dispatchers.Main) {
                    importMsg = ctx.getString(R.string.dns_import_saved)
                }
            } catch (_: Exception) {
                withContext(Dispatchers.Main) { importMsg = ctx.getString(R.string.dns_import_read_failed) }
            }
        }
    }
    val exportRules = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("text/plain")) { uri: Uri? ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch(Dispatchers.IO) {
            try {
                val text = vm.settings.value.dnsRules.joinToString("\n") {
                    if (it.kind == "override" && it.ip.isNotBlank()) "${it.ip} ${it.domain}" else "0.0.0.0 ${it.domain}"
                }
                ctx.contentResolver.openOutputStream(uri)?.use { it.write(text.toByteArray()) }
                withContext(Dispatchers.Main) { importMsg = ctx.getString(R.string.dns_export_saved) }
            } catch (_: Exception) {
                withContext(Dispatchers.Main) { importMsg = ctx.getString(R.string.dns_export_failed) }
            }
        }
    }

    val activePreset = DnsPresets.all.firstOrNull {
        settings.presetDns.size == 2 && it.primary == settings.presetDns[0] && it.secondary == settings.presetDns[1]
    }

    LazyColumn(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedButton(onClick = onBack) { Text("‹") }
                Spacer(Modifier.padding(4.dp))
                Text(stringResource(R.string.vpn_settings), style = MaterialTheme.typography.headlineSmall)
            }
        }
        item {
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(stringResource(R.string.protocol_title), style = MaterialTheme.typography.titleMedium)
                    Text(stringResource(R.string.ssh2_recommended))
                    Text(stringResource(R.string.ssh2_desc), style = MaterialTheme.typography.bodySmall)
                    Text(stringResource(R.string.protocol_desc), style = MaterialTheme.typography.bodySmall)
                }
            }
        }
        item {
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(stringResource(R.string.dns_settings), style = MaterialTheme.typography.titleMedium)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedButton(onClick = { dnsTab = 0 }, enabled = dnsTab != 0) { Text(stringResource(R.string.dns_tab_custom)) }
                        OutlinedButton(onClick = { dnsTab = 1 }, enabled = dnsTab != 1) { Text(stringResource(R.string.dns_tab_lists)) }
                    }
                    if (dnsTab == 0) {
                        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.clickable {
                            vm.saveSettings(settings.copy(useCustomDns = !settings.useCustomDns, presetDns = emptyList()))
                        }) {
                            Checkbox(settings.useCustomDns, null)
                            Text(stringResource(R.string.use_custom_dns))
                        }
                        if (settings.useCustomDns) {
                            OutlinedTextField(primary, { primary = it }, label = { Text(stringResource(R.string.primary_dns)) }, modifier = Modifier.fillMaxWidth())
                            OutlinedTextField(secondary, { secondary = it }, label = { Text(stringResource(R.string.secondary_dns)) }, modifier = Modifier.fillMaxWidth())
                            OutlinedButton(onClick = {
                                vm.saveSettings(settings.copy(primaryDns = primary.trim(), secondaryDns = secondary.trim(), presetDns = emptyList()))
                            }) { Text(stringResource(R.string.ok)) }
                            Text(stringResource(R.string.custom_dnshint), style = MaterialTheme.typography.bodySmall)
                        }
                        Text(stringResource(R.string.dns_presets_title))
                        DnsPresets.all.forEach { p ->
                            val sel = activePreset?.id == p.id
                            Row(
                                Modifier.fillMaxWidth().clickable {
                                    vm.applyPreset(if (sel) null else p.id)
                                    primary = p.primary; secondary = p.secondary
                                }.padding(vertical = 4.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Checkbox(sel, null)
                                Column {
                                    Text(p.name)
                                    Text("${p.primary}, ${p.secondary}  [${p.chips.joinToString()}]", style = MaterialTheme.typography.bodySmall)
                                    val descId = ctx.resources.getIdentifier(
                                        "dns_desc_${p.id.replace("-", "_")}", "string", ctx.packageName
                                    )
                                    if (descId != 0) Text(ctx.getString(descId), style = MaterialTheme.typography.bodySmall)
                                }
                            }
                        }
                    } else {
                        Text(stringResource(R.string.dns_lists_title), style = MaterialTheme.typography.titleMedium)
                        Text(stringResource(R.string.dns_lists_subtitle), style = MaterialTheme.typography.bodySmall)
                        val subIds = subs.map { it.id }.toSet()
                        DnsListCatalog.all.forEach { src ->
                            val sub = subs.firstOrNull { it.id == src.id }
                            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
                                Column(Modifier.weight(1f)) {
                                    Text(src.name)
                                    Text(
                                        "${src.category} • ~${src.entryCount}" +
                                            (sub?.let { " • ${it.domains}" } ?: "") +
                                            (if (sub?.failed == true) " • ${stringResource(R.string.dns_list_failed)}" else ""),
                                        style = MaterialTheme.typography.bodySmall
                                    )
                                }
                                if (src.id in subIds) {
                                    OutlinedButton(onClick = { vm.unsubscribeList(src.id) }) { Text("✓") }
                                } else {
                                    OutlinedButton(onClick = { vm.subscribeList(src.id) }) { Text("+") }
                                }
                            }
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            OutlinedButton(onClick = {
                                scope.launch(Dispatchers.IO) {
                                    for (s in subs) vm.lists.refresh(s.id)
                                    vm.refreshAsync()
                                }
                            }) { Text(stringResource(R.string.dns_lists_refresh_all)) }
                        }
                    }
                }
            }
        }
        item {
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(stringResource(R.string.dns_local_rules_title), style = MaterialTheme.typography.titleMedium)
                    Text(stringResource(R.string.dns_local_rules_info_body), style = MaterialTheme.typography.bodySmall)
                    settings.dnsRules.forEach { r ->
                        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
                            Text(
                                (if (r.kind == "block") stringResource(R.string.dns_rule_blocked) else stringResource(R.string.dns_rule_override)) +
                                    " ${r.domain}${if (r.sub) "+" else ""}${if (r.kind == "override") " → ${r.ip}" else ""}",
                                modifier = Modifier.weight(1f)
                            )
                            OutlinedButton(onClick = { vm.removeDnsRule(r.domain, r.kind) }) { Text("✕") }
                        }
                    }
                    if (settings.dnsRules.isEmpty()) Text(stringResource(R.string.dns_rules_empty), style = MaterialTheme.typography.bodySmall)
                    OutlinedTextField(newDomain, { newDomain = it }, label = { Text(stringResource(R.string.dns_add_rule_domain)) }, placeholder = { Text(stringResource(R.string.dns_add_rule_domain_placeholder)) }, modifier = Modifier.fillMaxWidth())
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Checkbox(newKindBlock, { newKindBlock = it })
                        Text(stringResource(R.string.dns_add_rule_mode_block))
                        Spacer(Modifier.padding(4.dp))
                        Checkbox(!newKindBlock, { newKindBlock = !it })
                        Text(stringResource(R.string.dns_add_rule_mode_override))
                    }
                    if (!newKindBlock) OutlinedTextField(newIp, { newIp = it }, label = { Text(stringResource(R.string.dns_add_rule_ip)) }, placeholder = { Text(stringResource(R.string.dns_add_rule_ipplaceholder)) }, modifier = Modifier.fillMaxWidth())
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.clickable { newSub = !newSub }) {
                        Checkbox(newSub, null)
                        Text(stringResource(R.string.dns_rule_scope_subtree))
                    }
                    ruleErrKey?.let {
                        Text(
                            stringResource(
                                when (it) {
                                    "dnsInvalidDomain" -> R.string.dns_invalid_domain
                                    "dnsInvalidIP" -> R.string.dns_invalid_ip
                                    else -> R.string.invalid_input
                                }
                            ), color = MaterialTheme.colorScheme.error
                        )
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedButton(onClick = {
                            ruleErrKey = vm.addDnsRule(newDomain, if (newKindBlock) "block" else "override", newIp, newSub)
                            if (ruleErrKey == null) { newDomain = ""; newIp = "" }
                        }) { Text(stringResource(R.string.dns_add_rule_add)) }
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedButton(onClick = { importRules.launch("*/*") }) { Text(stringResource(R.string.dns_import_from_file)) }
                        OutlinedButton(onClick = { exportRules.launch("dns-rules.txt") }) { Text(stringResource(R.string.dns_export_file)) }
                    }
                    importMsg?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
                }
            }
        }
        item {
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(stringResource(R.string.advanced), style = MaterialTheme.typography.titleMedium)
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.clickable {
                        vm.saveSettings(settings.copy(killSwitch = !settings.killSwitch))
                    }) {
                        Checkbox(settings.killSwitch, null)
                        Column {
                            Text(stringResource(R.string.kill_switch))
                            Text(stringResource(R.string.kill_switch_desc), style = MaterialTheme.typography.bodySmall)
                        }
                    }
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.clickable {
                        vm.setLogging(!settings.enableLogging)
                    }) {
                        Checkbox(settings.enableLogging, null)
                        Column {
                            Text(stringResource(R.string.enable_logging))
                            Text(stringResource(R.string.enable_logging_desc), style = MaterialTheme.typography.bodySmall)
                        }
                    }
                    Text(stringResource(R.string.connect_on_demand_desc), style = MaterialTheme.typography.bodySmall)
                    OutlinedButton(onClick = {
                        ctx.startActivity(Intent(Settings.ACTION_VPN_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    }) { Text(stringResource(R.string.connect_on_demand)) }
                }
            }
        }
        item {
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(stringResource(R.string.language_section), style = MaterialTheme.typography.titleMedium)
                    OutlinedButton(onClick = onLang, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.choose_language)) }
                    OutlinedButton(onClick = onDocs, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.documentation)) }
                    Text("${stringResource(R.string.about)} ${stringResource(R.string.version)} 1.0.0", style = MaterialTheme.typography.bodySmall)
                }
            }
        }
    }
}
