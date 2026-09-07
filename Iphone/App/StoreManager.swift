import Foundation
import StoreKit
import VPNCore

/// StoreKit 2 wrapper for the single one-time non-consumable product that
/// unlocks Unlimited (removes ads and the time limit). It only writes the
/// resulting entitlement into the SHARED keychain ledger — enforcement stays
/// in the extension, which reads the same ledger.
@MainActor
final class StoreManager: ObservableObject {
    static let unlimitedProductID = "com.sshtunnel.unlimited"

    @Published private(set) var product: Product?
    @Published private(set) var isPurchasing = false

    private var lastError: String?

    init() {
        // Refresh entitlement state on launch (restores across reinstall).
        Task { await loadProduct() }
    }

    func loadProduct() async {
        guard let p = try? await Product.products(for: [Self.unlimitedProductID]).first else {
            product = nil
            return
        }
        product = p
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
            if transaction.productID == Self.unlimitedProductID {
                owned = true
            }
        }
        if owned { applyUnlimited() }
        return owned
    }

    /// Buys the one-time Unlimited product. Returns an error message (nil on
    /// success). Marks the shared ledger unlimited on success.
    func purchaseUnlimited() async -> String? {
        guard let product else { return nil }
        guard !isPurchasing else { return nil }
        isPurchasing = true
        defer { isPurchasing = false }

        let result: Product.PurchaseResult
        do {
            result = try await product.purchase()
        } catch {
            lastError = error.localizedDescription
            return error.localizedDescription
        }
        switch result {
        case .success(let verification):
            switch verification {
            case .verified(let transaction):
                await transaction.finish()
                applyUnlimited()
                return nil
            case .unverified(_, let error):
                return error.localizedDescription
            }
        case .userCancelled:
            return nil
        case .pending:
            return nil
        @unknown default:
            return nil
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
