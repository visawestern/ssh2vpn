import Foundation
import StoreKit
import VPNCore

/// StoreKit 2 wrapper for the single one-time non-consumable product that
/// unlocks Unlimited (removes ads and the time limit). It only writes the
/// resulting entitlement into the SHARED keychain ledger — enforcement stays
/// in the extension, which reads the same ledger.
@MainActor
final class StoreManager: ObservableObject {
    static let unlimitedProductID = "com.ssh2vpn.unlimited"
    /// One-time $6 offer product — same entitlement as the full-price one,
    /// bought only from the paywall's discount stage.
    static let discountProductID = "com.ssh2vpn.unlimited.discount"
    /// Any of these product IDs grants Unlimited.
    static let entitledProductIDs: Set<String> = [unlimitedProductID, discountProductID]

    @Published private(set) var product: Product?
    @Published private(set) var discountProduct: Product?
    @Published private(set) var isPurchasing = false

    private var lastError: String?

    enum PurchaseOutcome: Equatable {
        case success
        case userCancelled
        case pending
        case failure(String)
    }

    init() {
        // Refresh entitlement state on launch (restores across reinstall).
        Task { await loadProduct() }
        // Required transaction-updates listener: StoreKit delivers some
        // transactions asynchronously (apple-id approval pages, purchases
        // started elsewhere), and without iterating Transaction.updates the
        // app risks missing a success outright.
        listenForTransactions()
    }

    /// Long-lived observer for asynchronous StoreKit transactions. Applies the
    /// unlimited entitlement whenever a verified purchase of our product shows
    /// up outside the direct `purchase(url:...)` path.
    private func listenForTransactions() {
        Task { [weak self] in
            for await result in Transaction.updates {
                guard case .verified(let transaction) = result,
                      Self.entitledProductIDs.contains(transaction.productID) else { continue }
                await transaction.finish()
                self?.applyUnlimited()
            }
        }
    }

    func loadProduct() async {
        let products = (try? await Product.products(for: [Self.unlimitedProductID, Self.discountProductID])) ?? []
        product = products.first { $0.id == Self.unlimitedProductID }
        discountProduct = products.first { $0.id == Self.discountProductID }
    }

    /// Refreshes the ledger's `unlimited` flag from App Store transactions.
    /// Called on launch and on Restore, so a prior purchase is honored even
    /// after reinstalling the app (the entitlement persists in the keychain
    /// too, but a fresh install that predates it still needs this).
    @discardableResult
    func refreshEntitlement() async -> Bool {
        var owned = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if Self.entitledProductIDs.contains(transaction.productID) {
                owned = true
            }
        }
        if owned { applyUnlimited() }
        return owned
    }

    /// Same entitlement check as `refreshEntitlement()`, but when the purchase
    /// is gone it also CLEARS the unlimited flag from the shared ledger (the
    /// keychain record the tunnel extension reads). Used on the periodic deep
    /// check so a refunded / deleted test purchase actually flips the app back
    /// to the free tier instead of staying stuck in the paid state forever.
    @discardableResult
    func refreshEntitlementClearingIfRevoked() async -> Bool {
        let owned = await refreshEntitlement()
        if !owned {
            let store = QuotaLedgerStore()
            var ledger = store.load()
            if ledger.unlimited {
                ledger = ledger.removingUnlimited()
                store.save(ledger)
            }
        }
        return owned
    }

    /// Buys the one-time Unlimited product. Returns a typed outcome so the UI
    /// can tell a real success from a user cancellation / pending approval /
    /// unavailable product — the old `String?` conflated "no product loaded"
    /// with success and silently ate failures.
    func purchaseUnlimited() async -> PurchaseOutcome {
        await purchase(product)
    }

    /// Buys the one-time $6 discount product (same Unlimited entitlement).
    /// Only reachable from the paywall's discount stage.
    func purchaseDiscount() async -> PurchaseOutcome {
        await purchase(discountProduct)
    }

    private func purchase(_ product: Product?) async -> PurchaseOutcome {
        guard let product else {
            let msg = lastError ?? "product not loaded"
            return .failure(msg)
        }
        guard !isPurchasing else { return .pending }
        isPurchasing = true
        defer { isPurchasing = false }

        let result: Product.PurchaseResult
        do {
            result = try await product.purchase()
        } catch {
            lastError = error.localizedDescription
            return .failure(error.localizedDescription)
        }
        switch result {
        case .success(let verification):
            switch verification {
            case .verified(let transaction):
                await transaction.finish()
                applyUnlimited()
                return .success
            case .unverified(_, let error):
                return .failure(error.localizedDescription)
            }
        case .userCancelled:
            return .userCancelled
        case .pending:
            return .pending
        @unknown default:
            return .pending
        }
    }

    /// Marks the shared ledger as unlimited (both app-side cache and keychain).
    private func applyUnlimited() {
        let store = QuotaLedgerStore()
        var ledger = store.load().withInitialGrant(now: Date())
        ledger = ledger.withUnlimited()
        store.save(ledger)
    }
}
