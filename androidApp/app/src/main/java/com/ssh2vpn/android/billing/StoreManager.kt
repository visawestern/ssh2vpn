package com.ssh2vpn.android.billing

import android.app.Activity
import android.content.Context
import com.android.billingclient.api.AcknowledgePurchaseParams
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingFlowParams
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.PendingPurchasesParams
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.PurchasesUpdatedListener
import com.android.billingclient.api.QueryProductDetailsParams
import com.ssh2vpn.android.data.ConsoleLog
import com.ssh2vpn.android.data.QuotaStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

/**
 * Покупка Unlimited — зеркало StoreManager (iOS):
 * два продукта (полный + discount для intro-стадии paywall),
 * исходы purchase/cancelled/pending/failure, слушатель асинхронных транзакций,
 * рефанд снимает Unlimited (refreshEntitlementClearingIfRevoked).
 *
 * ID продуктов заводятся в Play Console; discount — one-time продукт.
 */
class StoreManager(private val ctx: Context, private val scope: CoroutineScope) : PurchasesUpdatedListener {
    companion object {
        const val PRODUCT_UNLIMITED = "unlimited"
        const val PRODUCT_DISCOUNT = "unlimited_discount"
        val ENTITLED = setOf(PRODUCT_UNLIMITED, PRODUCT_DISCOUNT)
    }

    enum class PurchaseOutcome { SUCCESS, USER_CANCELLED, PENDING, FAILURE }

    private val _unlimited = MutableStateFlow(false)
    val unlimited: StateFlow<Boolean> = _unlimited
    private val _prices = MutableStateFlow(mapOf(PRODUCT_UNLIMITED to "$9.99", PRODUCT_DISCOUNT to "…"))
    val prices: StateFlow<Map<String, String>> = _prices
    private val _names = MutableStateFlow(mapOf<String, String>())
    val names: StateFlow<Map<String, String>> = _names
    private val _purchasing = MutableStateFlow(false)
    val purchasing: StateFlow<Boolean> = _purchasing
    private val _lastError = MutableStateFlow<String?>(null)
    val lastError: StateFlow<String?> = _lastError

    private var pendingOutcome: ((PurchaseOutcome, String?) -> Unit)? = null

    private val client: BillingClient = BillingClient.newBuilder(ctx)
        .setListener(this)
        .enablePendingPurchases(PendingPurchasesParams.newBuilder().enableOneTimeProducts().build())
        .build()

    init {
        client.startConnection(object : BillingClientStateListener {
            override fun onBillingSetupFinished(r: BillingResult) {
                if (r.responseCode == BillingClient.BillingResponseCode.OK) {
                    scope.launch { queryProducts(); refreshEntitlementClearingIfRevoked() }
                }
            }
            override fun onBillingServiceDisconnected() {}
        })
        scope.launch { _unlimited.value = QuotaStore(ctx).load().unlimited }
    }

    private suspend fun productDetails(): Map<String, com.android.billingclient.api.ProductDetails> =
        suspendCancellableCoroutine { cont ->
            val params = QueryProductDetailsParams.newBuilder()
                .setProductList(ENTITLED.map {
                    QueryProductDetailsParams.Product.newBuilder()
                        .setProductId(it).setProductType(BillingClient.ProductType.INAPP).build()
                }).build()
            client.queryProductDetailsAsync(params) { _, list ->
                if (cont.isActive) cont.resume(list.associateBy { it.productId })
            }
        }

    private suspend fun queryProducts() {
        try {
            val map = productDetails()
            _prices.value = ENTITLED.associateWith { id ->
                map[id]?.oneTimePurchaseOfferDetails?.formattedPrice ?: _prices.value[id].orEmpty()
            }
            _names.value = ENTITLED.associateWith { id -> map[id]?.name.orEmpty() }
        } catch (_: Exception) {}
    }

    fun buy(activity: Activity, productId: String, cb: (PurchaseOutcome, String?) -> Unit) {
        _purchasing.value = true
        _lastError.value = null
        scope.launch(Dispatchers.Main) {
            val map = try { productDetails() } catch (e: Exception) {
                _purchasing.value = false
                _lastError.value = e.message
                cb(PurchaseOutcome.FAILURE, e.message)
                return@launch
            }
            val d = map[productId]
            if (d == null) {
                _purchasing.value = false
                _lastError.value = "Продукт недоступен"
                cb(PurchaseOutcome.FAILURE, "Продукт недоступен")
                return@launch
            }
            pendingOutcome = cb
            val flow = BillingFlowParams.newBuilder()
                .setProductDetailsParamsList(listOf(
                    BillingFlowParams.ProductDetailsParams.newBuilder().setProductDetails(d).build()
                )).build()
            client.launchBillingFlow(activity, flow)
        }
    }

    fun restore(cb: ((Boolean) -> Unit)? = null) {
        scope.launch(Dispatchers.IO) {
            val owned = queryOwned()
            if (owned) {
                val q = QuotaStore(ctx)
                q.save(q.load().withUnlimited())
                _unlimited.value = true
            }
            scope.launch(Dispatchers.Main) { cb?.invoke(owned) }
        }
    }

    /** Есть ли активная покупка (для restore и проверки возвратов). */
    suspend fun queryOwned(): Boolean =
        suspendCancellableCoroutine { cont ->
            client.queryPurchasesAsync(
                com.android.billingclient.api.QueryPurchasesParams.newBuilder()
                    .setProductType(BillingClient.ProductType.INAPP).build()
            ) { _, purchases ->
                val owned = purchases.any {
                    it.products.any { p -> p in ENTITLED } && it.purchaseState == Purchase.PurchaseState.PURCHASED
                }
                if (cont.isActive) cont.resume(owned)
            }
        }

    /**
     * Порт refreshEntitlementClearingIfRevoked: возврат/отмена в Play снимает
     * Unlimited и возвращает free-tier (иначе — вечный доступ после рефанда).
     */
    suspend fun refreshEntitlementClearingIfRevoked(): Boolean {
        val owned = try { queryOwned() } catch (_: Exception) { return _unlimited.value }
        val q = QuotaStore(ctx)
        if (owned) {
            if (!q.load().unlimited) q.save(q.load().withUnlimited())
            _unlimited.value = true
        } else if (q.load().unlimited) {
            q.save(q.load().removingUnlimited())
            _unlimited.value = false
            ConsoleLog.log("warn", "STORE", "покупка отозвана — возврат во free-tier")
        }
        return owned
    }

    override fun onPurchasesUpdated(r: BillingResult, purchases: List<Purchase>?) {
        _purchasing.value = false
        val cb = pendingOutcome.also { pendingOutcome = null }
        when (r.responseCode) {
            BillingClient.BillingResponseCode.OK -> {
                val p = purchases?.firstOrNull { it.products.any { id -> id in ENTITLED } }
                if (p == null) { cb?.invoke(PurchaseOutcome.FAILURE, "Пустой ответ"); return }
                when (p.purchaseState) {
                    Purchase.PurchaseState.PURCHASED -> grant(p).also { cb?.invoke(PurchaseOutcome.SUCCESS, null) }
                    Purchase.PurchaseState.PENDING -> {
                        _lastError.value = "Ожидает подтверждения оплаты"
                        cb?.invoke(PurchaseOutcome.PENDING, "Ожидает подтверждения оплаты")
                    }
                    else -> cb?.invoke(PurchaseOutcome.FAILURE, "Неизвестный статус")
                }
            }
            BillingClient.BillingResponseCode.USER_CANCELED -> cb?.invoke(PurchaseOutcome.USER_CANCELLED, null)
            BillingClient.BillingResponseCode.ITEM_ALREADY_OWNED -> {
                scope.launch(Dispatchers.IO) { refreshEntitlementClearingIfRevoked() }
                cb?.invoke(PurchaseOutcome.SUCCESS, null)
            }
            else -> {
                _lastError.value = r.debugMessage
                cb?.invoke(PurchaseOutcome.FAILURE, r.debugMessage)
            }
        }
    }

    private fun grant(p: Purchase) {
        if (!p.isAcknowledged) {
            client.acknowledgePurchase(AcknowledgePurchaseParams.newBuilder().setPurchaseToken(p.purchaseToken).build()) {}
        }
        // TODO(Этап 3): verifyServerSide(p) перед грантом.
        scope.launch(Dispatchers.IO) {
            val q = QuotaStore(ctx)
            q.save(q.load().withUnlimited())
            _unlimited.value = true
            ConsoleLog.log("ok", "STORE", "Unlimited активирован")
        }
    }
}
