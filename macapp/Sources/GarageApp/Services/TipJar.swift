import Foundation
import StoreKit
import SwiftUI

/// The App Store build's tip jar: consumable in-app purchases that unlock nothing, offered on the
/// splash in place of the Patreon link (a link to an outside payment for a tip breaks App Review
/// guideline 3.1.1). The Developer ID build keeps the Patreon link and never touches StoreKit.
///
/// The products are made in App Store Connect under these identifiers, as Consumable in-app
/// purchases; `GarageTips.storekit` beside this module mirrors them for local testing (select it
/// in the scheme's Run options, or load it with `SKTestSession`).
enum TipProducts {
    static let small = "me.rickmark.garage_rag.tip.small"
    static let medium = "me.rickmark.garage_rag.tip.medium"
    static let large = "me.rickmark.garage_rag.tip.large"

    /// Smallest first, the order the splash shows them in.
    static let all = [small, medium, large]

    static func contains(_ productID: String) -> Bool {
        all.contains(productID)
    }

    /// `products` in the order of `all`, dropping anything that is not a tip. The App Store returns
    /// them in no particular order.
    static func ordered<Item>(_ products: [Item], id: (Item) -> String) -> [Item] {
        all.compactMap { wanted in products.first { id($0) == wanted } }
    }
}

/// Loads the tip products and records what became of a purchase, for `TipJarView`.
@MainActor
final class TipJar: ObservableObject {
    enum Phase: Equatable {
        case loading
        /// The products loaded and none is being bought.
        case ready
        /// The App Store returned no tip products (none made yet, or no connection).
        case unavailable
        case purchasing(productID: String)
        /// Waiting on approval (Ask to Buy, a payment method to confirm); `Transaction.updates`
        /// finishes it if it goes through.
        case pending
        case thanked
        case failed(String)
    }

    @Published private(set) var products: [Product] = []
    @Published private(set) var phase: Phase = .loading

    func load() async {
        do {
            let found = try await Product.products(for: TipProducts.all)
            products = TipProducts.ordered(found, id: \.id)
            phase = products.isEmpty ? .unavailable : .ready
        } catch {
            products = []
            phase = .unavailable
        }
    }

    /// Buys `product` through the view's `PurchaseAction`, which puts the App Store sheet on the
    /// view's window.
    func purchase(_ product: Product, with purchase: PurchaseAction) async {
        phase = .purchasing(productID: product.id)
        do {
            let result = try await purchase(product)
            record(result)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func record(_ result: Product.PurchaseResult) {
        switch result {
        case let .success(verification):
            // A tip unlocks nothing, so even an unverified transaction is only finished; leaving
            // it unfinished would replay it through `Transaction.updates` at every launch.
            let transaction = verification.unsafePayloadValue
            Task { await transaction.finish() }
            phase = .thanked
        case .pending:
            phase = .pending
        case .userCancelled:
            phase = .ready
        @unknown default:
            phase = .ready
        }
    }

    /// Finishes tip transactions that complete outside a purchase call: an approved Ask to Buy,
    /// a purchase interrupted by quitting, one made on another Mac. Started once at launch by the
    /// App Store build and kept for the life of the process.
    static func finishTransactionUpdates() -> Task<Void, Never> {
        Task.detached(priority: .background) {
            for await update in Transaction.updates {
                let transaction = update.unsafePayloadValue
                guard TipProducts.contains(transaction.productID) else { continue }
                await transaction.finish()
            }
        }
    }
}
