import AppKit
import Foundation
import StoreKit

/// In-app purchase for the paid unlock.
///
/// Product configuration lives in App Store Connect (see `appstore/SUBMISSION.md`):
///   Product ID : com.gopromount.goprocard.pro
///   Type       : Non-consumable
///   Price      : $9.99 (App Store price point 11, "Tier 10")
///
/// The purchase flow is complete, but `Store.enforcementEnabled` is false in the
/// locally-built app so that an existing install never gets locked out. Flip it to true
/// (or build with `-DSTORE_ENFORCEMENT`) once the product exists in App Store Connect.
final class Store: ObservableObject {
    static let productID = "com.gopromount.goprocard.pro"

    #if STORE_ENFORCEMENT
    static let enforcementEnabled = true
    #else
    static let enforcementEnabled = false
    #endif

    static let shared = Store()

    @Published private(set) var product: Product?
    @Published private(set) var isUnlocked = false
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?

    private var updatesTask: Task<Void, Never>?
    private let unlockedKey = "proUnlocked"

    private init() {
        isUnlocked = UserDefaults.standard.bool(forKey: unlockedKey) || !Store.enforcementEnabled
    }

    var priceText: String {
        product?.displayPrice ?? "$9.99"
    }

    var isConfigured: Bool {
        product != nil
    }

    func start() {
        guard Store.enforcementEnabled else {
            log("store: enforcement disabled in this build")
            return
        }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update)
            }
        }
        Task {
            await loadProduct()
            await refreshEntitlements()
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    // MARK: - StoreKit

    func loadProduct() async {
        do {
            let products = try await Product.products(for: [Store.productID])
            await MainActor.run { self.product = products.first }
            if products.isEmpty {
                log("store: product \(Store.productID) not found — check App Store Connect")
            }
        } catch {
            log("store: could not load products: \(error)")
            await MainActor.run { self.errorMessage = error.localizedDescription }
        }
    }

    func purchase() async {
        guard let product = product else {
            await MainActor.run { self.errorMessage = "The App Store product is not available yet." }
            return
        }
        await MainActor.run { self.isBusy = true }
        defer { Task { await MainActor.run { self.isBusy = false } } }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                await handle(verification)
            case .userCancelled:
                break
            case .pending:
                await MainActor.run { self.errorMessage = "Purchase is pending approval." }
            @unknown default:
                break
            }
        } catch {
            log("store: purchase failed: \(error)")
            await MainActor.run { self.errorMessage = error.localizedDescription }
        }
    }

    func restore() async {
        await MainActor.run { self.isBusy = true }
        defer { Task { await MainActor.run { self.isBusy = false } } }

        do {
            try await AppStore.sync()
            await refreshEntitlements()
        } catch {
            await MainActor.run { self.errorMessage = error.localizedDescription }
        }
    }

    private func handle(_ verification: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = verification else {
            log("store: unverified transaction ignored")
            return
        }
        if transaction.productID == Store.productID {
            await MainActor.run {
                self.isUnlocked = true
                UserDefaults.standard.set(true, forKey: self.unlockedKey)
            }
        }
        await transaction.finish()
    }

    private func refreshEntitlements() async {
        var owned = false
        for await entitlement in Transaction.currentEntitlements {
            if case .verified(let transaction) = entitlement,
               transaction.productID == Store.productID {
                owned = true
            }
        }
        if !Store.enforcementEnabled { owned = true }
        let final = owned
        await MainActor.run {
            self.isUnlocked = final
            UserDefaults.standard.set(final, forKey: self.unlockedKey)
        }
    }

    // MARK: - Paywall UI

    func makePaywallAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Unlock GoPro Card"
        alert.informativeText = """
        GoPro Card mounts your camera as a Finder drive.

        One-time purchase — \(priceText). No subscription.
        """
        alert.addButton(withTitle: "Buy for \(priceText)")
        alert.addButton(withTitle: "Restore Purchase")
        alert.addButton(withTitle: "Not Now")
        return alert
    }
}
