import StoreKit
import SwiftUI

/// The splash's tip buttons in the App Store build: one per tip product, priced by the App Store
/// in the buyer's currency. Nothing shows when the store returns no products.
struct TipJarView: View {
    @StateObject private var tipJar = TipJar()
    @Environment(\.purchase) private var purchase

    var body: some View {
        Group {
            switch tipJar.phase {
            case .loading:
                ProgressView()
                    .controlSize(.small)
            case .unavailable:
                EmptyView()
            case .thanked:
                Label("Thank you! Your tip keeps Garage going.", systemImage: "heart.fill")
                    .foregroundStyle(.pink)
                    .accessibilityIdentifier("splash.tipThanks")
            default:
                offer
            }
        }
        .task { await tipJar.load() }
    }

    private var offer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("If Garage saves you time, you can leave a tip. It unlocks nothing; every feature is free.")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(tipJar.products, id: \.id) { product in
                    Button {
                        Task { await tipJar.purchase(product, with: purchase) }
                    } label: {
                        Label("Tip \(product.displayPrice)", systemImage: "heart")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.pink)
                    .disabled(isPurchasing)
                    .accessibilityIdentifier("splash.tip.\(product.id)")
                }
                if isPurchasing {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            switch tipJar.phase {
            case .pending:
                Text("Your tip is waiting for approval.")
                    .foregroundStyle(.secondary)
            case let .failed(message):
                Text("The tip didn't go through: \(message)")
                    .foregroundStyle(.red)
            default:
                EmptyView()
            }
        }
    }

    private var isPurchasing: Bool {
        if case .purchasing = tipJar.phase { return true }
        return false
    }
}
