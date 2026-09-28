import StoreKit
import StoreKitTest
import XCTest
@testable import GarageApp

final class TipJarTests: XCTestCase {

    func testOnlyTheAppStoreBuildOffersTheTipJar() {
        XCTAssertTrue(AppVersionInfo(shortVersion: "1.5", build: "80", distribution: .appStore).offersTipJar)
        XCTAssertFalse(AppVersionInfo(shortVersion: "1.5", build: "80", distribution: .developerID).offersTipJar)
        XCTAssertFalse(AppVersionInfo(shortVersion: nil, build: nil).offersTipJar)
    }

    func testTipsAreOrderedSmallestFirstAndStrangersDropped() {
        let shuffled = [TipProducts.large, "me.rickmark.garage_rag.other", TipProducts.small, TipProducts.medium]
        XCTAssertEqual(TipProducts.ordered(shuffled, id: { $0 }), TipProducts.all)
        XCTAssertEqual(TipProducts.ordered([TipProducts.large], id: { $0 }), [TipProducts.large])
    }

    /// App Store Connect product identifiers take letters, digits, periods and underscores only.
    func testProductIdentifiersAreValidForAppStoreConnect() {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._"))
        for id in TipProducts.all {
            XCTAssertTrue(id.unicodeScalars.allSatisfy(allowed.contains), id)
        }
    }

    /// GarageTips.storekit lists exactly the tip products, all consumable.
    func testStoreKitConfigurationMatchesTheProducts() throws {
        let data = try Data(contentsOf: try storeKitConfigurationURL())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let products = try XCTUnwrap(json["products"] as? [[String: Any]])
        XCTAssertEqual(products.compactMap { $0["productID"] as? String }, TipProducts.all)
        XCTAssertEqual(Set(products.compactMap { $0["type"] as? String }), ["Consumable"])
    }

    /// The products load from the local StoreKit configuration, and a purchase finishes.
    @MainActor
    func testTipsLoadAndPurchaseInTheStoreKitTestSession() async throws {
        let session = try SKTestSession(contentsOf: try storeKitConfigurationURL())
        session.disableDialogs = true
        session.clearTransactions()

        let tipJar = TipJar()
        await tipJar.load()
        XCTAssertEqual(tipJar.phase, .ready)
        XCTAssertEqual(tipJar.products.map(\.id), TipProducts.all)
        XCTAssertEqual(tipJar.products.map(\.type), [.consumable, .consumable, .consumable])

        let result = try await tipJar.products[0].purchase()
        guard case let .success(verification) = result else {
            return XCTFail("expected the tip purchase to succeed, got \(result)")
        }
        await verification.unsafePayloadValue.finish()
        XCTAssertEqual(session.allTransactions().count, 1)
    }

    /// macapp/Sources/GarageApp/GarageTips.storekit, from the test bundle's resources or Bazel's runfiles.
    private func storeKitConfigurationURL() throws -> URL {
        let candidates = [
            Bundle(for: Self.self).url(forResource: "GarageTips", withExtension: "storekit"),
            ProcessInfo.processInfo.environment["TEST_SRCDIR"].map {
                URL(fileURLWithPath: $0).appendingPathComponent("_main/macapp/Sources/GarageApp/GarageTips.storekit")
            },
        ].compactMap { $0 }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw XCTSkip("GarageTips.storekit is not in this test's runfiles")
        }
        return url
    }
}
