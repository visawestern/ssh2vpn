package com.ssh2vpn.android.ui

import android.webkit.WebView
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.Checkbox
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import com.ssh2vpn.android.R
import com.ssh2vpn.android.data.AppLanguage
import java.util.Locale

/** Privacy gate при первом запуске — порт privacyDisclosureAcknowledged. */
@Composable
fun ShowPrivacyGate(onAccept: () -> Unit) {
    var showDocs by remember { mutableStateOf<String?>(null) }
    AlertDialog(
        onDismissRequest = {},
        confirmButton = {
            TextButton(onClick = onAccept) { Text(stringResource(R.string.ok)) }
        },
        dismissButton = {
            TextButton(onClick = { showDocs = "privacy.html" }) {
                Text(stringResource(R.string.privacy_policy_title))
            }
        },
        title = { Text(stringResource(R.string.privacy_policy_title)) },
        text = { Text(stringResource(R.string.privacy_policy_desc)) }
    )
    showDocs?.let { DocSheet(file = it, onClose = { showDocs = null }) }
}

/** Документы: privacy/terms из тех же HTML, что в iOS-бандле. */
@Composable
fun ScreenDocs(onBack: () -> Unit) {
    var tab by remember { mutableStateOf(0) }
    Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedButton(onClick = onBack) { Text("‹") }
            Text(
                stringResource(R.string.documentation),
                style = MaterialTheme.typography.headlineSmall,
                modifier = Modifier.padding(start = 8.dp)
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = { tab = 0 }, enabled = tab != 0) { Text(stringResource(R.string.privacy_policy_title)) }
            OutlinedButton(onClick = { tab = 1 }, enabled = tab != 1) { Text(stringResource(R.string.terms_of_use_title)) }
        }
        Card(Modifier.fillMaxSize()) {
            AndroidView(
                factory = { c -> WebView(c).apply { settings.javaScriptEnabled = false } },
                update = { w -> w.loadUrl("file:///android_asset/docs/${if (tab == 0) "privacy.html" else "terms.html"}") },
                modifier = Modifier.fillMaxSize()
            )
        }
    }
}

@Composable
private fun DocSheet(file: String, onClose: () -> Unit) {
    Dialog(onDismissRequest = onClose) {
        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                AndroidView(
                    factory = { c -> WebView(c).apply { settings.javaScriptEnabled = false } },
                    update = { w -> w.loadUrl("file:///android_asset/docs/$file") },
                    modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp)
                )
                Button(onClick = onClose, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.ok)) }
            }
        }
    }
}

/** Выбор языка — порт LanguageStore + first-launch оверлей (хинт: локаль устройства). */
@Composable
fun ScreenLanguagePicker(vm: AppViewModel, onBack: () -> Unit) {
    val ctx = LocalContext.current
    val langs = remember {
        AppLanguage.ordered(
            Locale.getDefault().toLanguageTag(),
            try { Locale.getDefault().country } catch (_: Exception) { null }
        )
    }
    var current by remember { mutableStateOf(vm.lang.current()?.tag) }
    LazyColumn(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedButton(onClick = onBack) { Text("‹") }
                Text(
                    stringResource(R.string.choose_language),
                    style = MaterialTheme.typography.headlineSmall,
                    modifier = Modifier.padding(start = 8.dp)
                )
            }
        }
        items(langs) { l ->
            Row(
                Modifier.fillMaxWidth().clickable {
                    vm.lang.apply(l.tag)
                    current = l.tag
                    vm.refreshAsync()
                }.padding(vertical = 10.dp, horizontal = 4.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Checkbox(current == l.tag, null)
                Text("${l.flag}  ${l.title}")
            }
        }
    }
}

/** First-launch оверлей выбора языка (показывается один раз). */
@Composable
fun ShowFirstLaunchLanguage(vm: AppViewModel, onDone: () -> Unit) {
    val langs = remember {
        AppLanguage.ordered(
            Locale.getDefault().toLanguageTag(), null
        )
    }
    Dialog(onDismissRequest = {}) {
        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(stringResource(R.string.choose_language), style = MaterialTheme.typography.headlineSmall)
                Text(stringResource(R.string.select_language_hint), style = MaterialTheme.typography.bodySmall)
                LazyColumn(Modifier.fillMaxWidth()) {
                    items(langs.take(8)) { l ->
                        Row(
                            Modifier.fillMaxWidth().clickable {
                                vm.lang.apply(l.tag)
                                onDone()
                            }.padding(vertical = 10.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text("${l.flag}  ${l.title}")
                        }
                    }
                }
                OutlinedButton(onClick = onDone, modifier = Modifier.fillMaxWidth()) {
                    Text(stringResource(R.string.choose_language))
                }
            }
        }
    }
}
