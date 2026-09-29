import XCTest
@testable import GarageApp

final class TipJarTests: XCTestCase {

    func testOnlyTheAppStoreBuildOffersTheTipJar() {
        XCTAssertTrue(AppVersionInfo(shortVersion: "1.5", build: "80", distribution: .appStore).offersTipJar)
        XCTAssertFalse(AppVersionInfo(shortVersion: "1.5", build: "80", distribution: .developerID).offersTipJar)
        XCTAssertFalse(AppVersionInfo(shortVersion: nil, build: nil).offersTipJar)
    }

    func testTipsAreOrderedSmallestFirstAndStrangersDropped() {
        let shuffled = [
            TipProducts.ultra, TipProducts.large, "me.rickmark.garage_rag.other", TipProducts.small,
            TipProducts.max, TipProducts.medium,
        ]
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

    /// GarageTips.storekit lists exactly the tip products, all consumable. A purchase against it needs
    /// an app to host the StoreKit test session (an unhosted xctest gets SKInternalErrorDomain 3), so
    /// it is checked by running the app from Xcode with the configuration selected (README, "Tip jar").
    func testStoreKitConfigurationMatchesTheProducts() throws {
        let data = try Data(contentsOf: try storeKitConfigurationURL())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let products = try XCTUnwrap(json["products"] as? [[String: Any]])
        XCTAssertEqual(products.compactMap { $0["productID"] as? String }, TipProducts.all)
        XCTAssertEqual(Set(products.compactMap { $0["type"] as? String }), ["Consumable"])
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
