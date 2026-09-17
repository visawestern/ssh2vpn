package com.ssh2vpn.android.ui

import android.app.Activity
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.ssh2vpn.android.R
import com.ssh2vpn.android.billing.StoreManager

/** Paywall — стадии full/discount как в iOS (без таймеров-пугалок, цены из Play). */
@Composable
fun ScreenPaywall(vm: AppViewModel, onBack: () -> Unit) {
    val ctx = LocalContext.current
    val activity = ctx as? Activity
    val stage by vm.paywallStage.collectAsState()
    val prices by vm.store.prices.collectAsState()
    val names by vm.store.names.collectAsState()
    val purchasing by vm.store.purchasing.collectAsState()
    val storeErr by vm.store.lastError.collectAsState()
    var outcome by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(Unit) { vm.markPaywallSeen() }

    val isDiscount = stage == "discount"
    val fullPrice = prices[StoreManager.PRODUCT_UNLIMITED].orEmpty().ifBlank { "…" }
    val discPrice = prices[StoreManager.PRODUCT_DISCOUNT].orEmpty().ifBlank { "…" }
    val price = if (isDiscount) discPrice else fullPrice
    val discountPct = remember(fullPrice, discPrice) {
        val f = fullPrice.filter { it.isDigit() || it == '.' }.toDoubleOrNull()
        val d = discPrice.filter { it.isDigit() || it == '.' }.toDoubleOrNull()
        if (f != null && d != null && f > d && f > 0) "-${((1 - d / f) * 100).toInt()}%" else null
    }

    LazyColumn(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedButton(onClick = onBack) { Text("‹") }
                Spacer(Modifier.padding(4.dp))
                Text(stringResource(R.string.unlimited_badge), style = MaterialTheme.typography.headlineSmall)
            }
        }
        item {
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (isDiscount) {
                        discountPct?.let { Text(stringResource(R.string.paywall_discount_tag), color = Octo.Prim100) }
                        Text(priceText(ctx, R.string.paywall_discount_title, price))
                        Text(stringResource(R.string.paywall_discount_subtitle), style = MaterialTheme.typography.bodySmall)
                    } else {
                        Text(priceText(ctx, R.string.paywall_title, price))
                        Text(stringResource(R.string.paywall_subtitle), style = MaterialTheme.typography.bodySmall)
                    }
                    Text("✓ ${stringResource(R.string.paywall_feature_unlimited)}")
                    Text("✓ ${stringResource(R.string.paywall_feature_no_ads)}")
                    Text(stringResource(R.string.paywall_one_time), style = MaterialTheme.typography.bodySmall)
                    Text(stringResource(R.string.buy_unlimited_desc), style = MaterialTheme.typography.bodySmall)
                    Button(
                        onClick = {
                            if (activity == null) return@Button
                            val pid = if (isDiscount) StoreManager.PRODUCT_DISCOUNT else StoreManager.PRODUCT_UNLIMITED
                            vm.store.buy(activity, pid) { oc, err ->
                                outcome = when (oc) {
                                    StoreManager.PurchaseOutcome.SUCCESS -> null.also { onBack() }
                                    StoreManager.PurchaseOutcome.USER_CANCELLED -> null
                                    StoreManager.PurchaseOutcome.PENDING -> ctx.getString(R.string.purchasing)
                                    StoreManager.PurchaseOutcome.FAILURE ->
                                        err ?: ctx.getString(R.string.purchase_unavailable)
                                }
                                vm.refreshAsync()
                            }
                        },
                        enabled = !purchasing,
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Text(
                            if (isDiscount) "${stringResource(R.string.paywall_buy_discount)} — $price"
                            else "${stringResource(R.string.buy_unlimited)} — $price"
                        )
                    }
                    if (!names.values.all { it.isBlank() }) {
                        Text(names[StoreManager.PRODUCT_UNLIMITED].orEmpty(), style = MaterialTheme.typography.bodySmall)
                    }
                    (outcome ?: storeErr)?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                    OutlinedButton(
                        onClick = {
                            vm.store.restore { owned ->
                                outcome = if (owned) null.also { onBack() } else ctx.getString(R.string.restore_error)
                                vm.refreshAsync()
                            }
                        },
                        modifier = Modifier.fillMaxWidth()
                    ) { Text(stringResource(R.string.restore_purchase)) }
                }
            }
        }
    }
}
