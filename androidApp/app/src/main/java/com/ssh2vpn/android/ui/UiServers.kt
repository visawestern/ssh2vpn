package com.ssh2vpn.android.ui

import android.net.Uri
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
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.Checkbox
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import com.ssh2vpn.android.R
import com.ssh2vpn.android.ssh.SshKeyParser
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** My Servers — флаг/страна/пинг/алиас, выбор, удаление с подтверждением. */
@Composable
fun ScreenServers(vm: AppViewModel, onAdd: () -> Unit, onBack: () -> Unit) {
    val rows by vm.rows.collectAsState()
    val selectedId by vm.selectedId.collectAsState()
    var deleteId by remember { mutableStateOf<String?>(null) }
    Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedButton(onClick = onBack) { Text("‹") }
            Spacer(Modifier.padding(4.dp))
            Text(stringResource(R.string.locations), style = MaterialTheme.typography.headlineSmall)
        }
        Button(onClick = onAdd, modifier = Modifier.fillMaxWidth()) {
            Text("+ ${stringResource(R.string.add_server)}")
        }
        if (rows.isEmpty()) {
            Text(stringResource(R.string.no_server_configured))
        }
        LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items(rows) { r ->
                val s = r.profile
                Card(Modifier.fillMaxWidth().clickable { vm.select(s.id) }) {
                    Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(
                            (if (s.id == selectedId) "● " else "○ ") +
                                "${r.flag} ${s.displayAddress}",
                            style = MaterialTheme.typography.titleMedium
                        )
                        if (s.hasCustomLabel) Text("${s.host}:${s.port}", style = MaterialTheme.typography.bodySmall)
                        Text(
                            "${s.username}  •  ${stringResource(R.string.ping)}: " +
                                "${r.pingMs?.let { "$it ms" } ?: "…"}  •  " +
                                "${r.countryCode ?: "—"}",
                            style = MaterialTheme.typography.bodySmall
                        )
                        Text(
                            "auth: " + listOfNotNull(
                                "password".takeIf { s.hasPassword },
                                "key".takeIf { s.hasPrivateKey },
                                "host-key".takeIf { s.hostKey.isNotBlank() }
                            ).joinToString().ifBlank { "—" },
                            style = MaterialTheme.typography.bodySmall
                        )
                        OutlinedButton(onClick = { deleteId = s.id }) {
                            Text(stringResource(R.string.delete_server))
                        }
                    }
                }
            }
        }
    }
    if (deleteId != null) {
        AlertDialog(
            onDismissRequest = { deleteId = null },
            confirmButton = {
                TextButton(onClick = { vm.deleteServer(deleteId!!); deleteId = null }) {
                    Text(stringResource(R.string.delete_server))
                }
            },
            dismissButton = {
                TextButton(onClick = { deleteId = null }) { Text(stringResource(R.string.cancel)) }
            },
            title = { Text(stringResource(R.string.delete_server)) },
            text = { Text(stringResource(R.string.delete_server_confirm)) }
        )
    }
}

/** Разбор «вставь что угодно»: ssh://user@host:port, user@host, ключ в тексте. */
internal fun parsePastedCredentials(text: String): Map<String, String> {
    val out = mutableMapOf<String, String>()
    val t = text.trim()
    Regex("""ssh://([^@\s]+)@([^:/\s]+)(?::(\d+))?""").find(t)?.let {
        out["username"] = it.groupValues[1]
        out["host"] = it.groupValues[2]
        if (it.groupValues[3].isNotEmpty()) out["port"] = it.groupValues[3]
    }
    if (out.isEmpty()) {
        Regex("""(?m)^\s*ssh\s+([A-Za-z0-9_.\-]+)@([A-Za-z0-9_.\-]+)(?:\s+-p\s*(\d+))?""").find(t)?.let {
            out["username"] = it.groupValues[1]
            out["host"] = it.groupValues[2]
            if (it.groupValues[3].isNotEmpty()) out["port"] = it.groupValues[3]
        }
    }
    if (out.isEmpty()) {
        Regex("""([A-Za-z0-9_.\-]+)@([A-Za-z0-9_.\-]+)""").find(t)?.let {
            out["username"] = it.groupValues[1]
            out["host"] = it.groupValues[2]
        }
    }
    if ("OPENSSH PRIVATE KEY" in t || "BEGIN PRIVATE KEY" in t || "BEGIN RSA PRIVATE KEY" in t) {
        val key = t.lines().filter {
            it.startsWith("-----") || it.isNotBlank() && !it.trimStart().startsWith("ssh ")
        }.joinToString("\n")
        out["key"] = t.substringAfter("-----BEGIN").let { "-----BEGIN$it" }
            .substringBeforeLast("-----END").let { "$it-----END${t.substringAfterLast("-----END").takeWhile { c -> c != '\n' }}" }
        if (out["key"]!!.length < 100) out["key"] = key
    }
    return out
}

/** Add/Edit Server — форма как в iOS §19 + alias + hostkey + импорт. */
@Composable
fun ScreenAddServer(vm: AppViewModel, onDone: () -> Unit, editId: String? = null) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var name by remember { mutableStateOf("") }
    var alias by remember { mutableStateOf("") }
    var host by remember { mutableStateOf("") }
    var port by remember { mutableStateOf("22") }
    var username by remember { mutableStateOf("root") }
    var password by remember { mutableStateOf("") }
    var keyText by remember { mutableStateOf("") }
    var hostKeyText by remember { mutableStateOf("") }
    var showKey by remember { mutableStateOf(false) }
    var showHostKey by remember { mutableStateOf(false) }
    var showImport by remember { mutableStateOf(false) }
    var paste by remember { mutableStateOf("") }
    var msg by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    val testing by vm.testing.collectAsState()

    val keyFilePicker = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri: Uri? ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch(Dispatchers.IO) {
            try {
                ctx.contentResolver.openInputStream(uri)?.use { inp ->
                    val text = inp.bufferedReader().readText()
                    if (text.length > 100_000) {
                        withContext(Dispatchers.Main) { msg = ctx.getString(R.string.key_import_too_large) }
                        return@use
                    }
                    withContext(Dispatchers.Main) { keyText = text.trim(); showKey = true }
                }
            } catch (_: Exception) {
                withContext(Dispatchers.Main) { msg = ctx.getString(R.string.key_import_read_failed) }
            }
        }
    }

    Dialog(onDismissRequest = { if (!busy) onDone() }) {
        Card(Modifier.fillMaxWidth()) {
            LazyColumn(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                item { Text(stringResource(R.string.add_server_title), style = MaterialTheme.typography.headlineSmall) }
                item {
                    OutlinedTextField(name, { name = it }, label = { Text(stringResource(R.string.server)) }, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(alias, { alias = it }, label = { Text(stringResource(R.string.server_label_optional)) }, placeholder = { Text(stringResource(R.string.server_label_placeholder)) }, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(host, { host = it }, label = { Text(stringResource(R.string.address)) }, placeholder = { Text(stringResource(R.string.address_placeholder)) }, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(username, { username = it }, label = { Text(stringResource(R.string.username)) }, placeholder = { Text(stringResource(R.string.username_placeholder)) }, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(password, { password = it }, label = { Text(stringResource(R.string.password_optional)) }, placeholder = { Text(stringResource(R.string.password_placeholder)) }, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(
                        port, { port = it.filter { c -> c.isDigit() }.take(5) },
                        label = { Text(stringResource(R.string.ssh_port)) },
                        placeholder = { Text(stringResource(R.string.port_placeholder)) },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        modifier = Modifier.fillMaxWidth()
                    )
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.clickable { showKey = !showKey }) {
                        Checkbox(showKey, { showKey = it })
                        Text(stringResource(R.string.ed25519_private_key_optional))
                    }
                    if (showKey) {
                        OutlinedTextField(keyText, { keyText = it }, label = { Text("OpenSSH") }, placeholder = { Text(stringResource(R.string.private_key_placeholder)) }, modifier = Modifier.fillMaxWidth(), minLines = 3)
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            OutlinedButton(onClick = { keyFilePicker.launch("*/*") }) {
                                Text(stringResource(R.string.key_import_from_file))
                            }
                            OutlinedButton(onClick = { showImport = true }) {
                                Text(stringResource(R.string.import_title))
                            }
                        }
                        Text(stringResource(R.string.ed25519_hint), style = MaterialTheme.typography.bodySmall)
                    }
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.clickable { showHostKey = !showHostKey }) {
                        Checkbox(showHostKey, { showHostKey = it })
                        Text(stringResource(R.string.pinned_host_key))
                    }
                    if (showHostKey) {
                        OutlinedTextField(hostKeyText, { hostKeyText = it }, label = { Text(stringResource(R.string.pinned_host_key)) }, placeholder = { Text(stringResource(R.string.host_key_placeholder)) }, modifier = Modifier.fillMaxWidth(), minLines = 2)
                    }
                    testing?.let {
                        Text(
                            when {
                                it == "testing" -> stringResource(R.string.testing_tunnel)
                                it.startsWith("ok:") -> "✓ SSH connection successful\n✓ Tunnel supported (forwarding probe OK)"
                                else -> "✗ " + it.removePrefix("err:")
                            }
                        )
                    }
                    msg?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                }
                item {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                        OutlinedButton(onClick = onDone, enabled = !busy, modifier = Modifier.weight(1f)) { Text(stringResource(R.string.cancel)) }
                        Button(
                            onClick = {
                                var pem: String? = null
                                if (keyText.isNotBlank()) {
                                    try {
                                        SshKeyParser.normalizeEd25519Seed(keyText)
                                        pem = keyText.trim()
                                    } catch (e: Exception) {
                                        msg = e.message; return@Button
                                    }
                                }
                                busy = true; msg = null
                                vm.testAndSave(
                                    editId, name.trim(), host.trim(), port.toIntOrNull() ?: 0,
                                    username.trim(),
                                    password.ifBlank { null }, pem,
                                    hostKeyText.ifBlank { null },
                                    alias.ifBlank { null }
                                ) { ok, m ->
                                    busy = false
                                    if (ok) onDone() else msg = m
                                }
                            },
                            enabled = !busy, modifier = Modifier.weight(1f)
                        ) { Text(stringResource(R.string.test_connection)) }
                    }
                }
            }
        }
    }
    if (showImport) {
        Dialog(onDismissRequest = { showImport = false }) {
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(stringResource(R.string.import_title), style = MaterialTheme.typography.headlineSmall)
                    Text(stringResource(R.string.import_subtitle), style = MaterialTheme.typography.bodySmall)
                    OutlinedTextField(paste, { paste = it }, placeholder = { Text(stringResource(R.string.import_placeholder)) }, modifier = Modifier.fillMaxWidth(), minLines = 5)
                    msg?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                        OutlinedButton(onClick = { showImport = false }, modifier = Modifier.weight(1f)) { Text(stringResource(R.string.cancel)) }
                        Button(
                            onClick = {
                                val p = parsePastedCredentials(paste)
                                if (p.isEmpty()) { msg = ctx.getString(R.string.import_parse_failed); return@Button }
                                p["host"]?.let { host = it }
                                p["username"]?.let { username = it }
                                p["port"]?.let { port = it }
                                p["key"]?.let { keyText = it; showKey = true }
                                showImport = false
                                msg = null
                            },
                            modifier = Modifier.weight(1f)
                        ) { Text(stringResource(R.string.import_parse_button)) }
                    }
                }
            }
        }
    }
}
