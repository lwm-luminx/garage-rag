import XCTest
import SwiftUI
import AppKit
import PythonXPCService
@testable import GarageApp

final class SplashViewTests: XCTestCase {

    func testLinksPointAtExpectedDestinations() {
        XCTAssertEqual(SplashLinks.patreon.absoluteString, "https://www.patreon.com/rickmark")
    }

    func testVersionDisplayWithVersionAndDistinctBuild() {
        let info = AppVersionInfo(shortVersion: "0.9", build: "42")
        XCTAssertEqual(info.displayString, "Version 0.9 (build 42)")
    }

    func testVersionDisplayOmitsBuildWhenIdenticalToVersion() {
        let info = AppVersionInfo(shortVersion: "0.9", build: "0.9")
        XCTAssertEqual(info.displayString, "Version 0.9")
    }

    func testVersionDisplayWithVersionOnly() {
        let info = AppVersionInfo(shortVersion: "0.9", build: nil)
        XCTAssertEqual(info.displayString, "Version 0.9")
    }

    func testVersionDisplayWithBuildOnly() {
        let info = AppVersionInfo(shortVersion: nil, build: "42")
        XCTAssertEqual(info.displayString, "Build 42")
    }

    func testVersionDisplayFallsBackForMissingOrBlankValues() {
        XCTAssertEqual(AppVersionInfo(shortVersion: nil, build: nil).displayString, "Development build")
        XCTAssertEqual(AppVersionInfo(shortVersion: "  ", build: "").displayString, "Development build")
    }

    func testVersionDisplayNamesTheDistribution() {
        XCTAssertEqual(
            AppVersionInfo(shortVersion: "1.5.0", build: "80", distribution: .appStore).displayString,
            "Version 1.5.0 (build 80) · App Store"
        )
        XCTAssertEqual(
            AppVersionInfo(shortVersion: "1.5.0", build: nil, distribution: .developerID).displayString,
            "Version 1.5.0 · Developer ID"
        )
    }

    func testOnlyTheAppStoreBuildLeavesOutTheDonationLink() {
        XCTAssertFalse(AppVersionInfo(shortVersion: "1.5", build: "80", distribution: .appStore).offersDonationLink)
        XCTAssertTrue(AppVersionInfo(shortVersion: "1.5", build: "80", distribution: .developerID).offersDonationLink)
        XCTAssertTrue(AppVersionInfo(shortVersion: nil, build: nil).offersDonationLink)
    }

    func testVersionInfoFromBundleNamesTheRunningDistribution() {
        let expected: AppVersionInfo.Distribution = GarageAppGroup.isSandboxed ? .appStore : .developerID
        XCTAssertEqual(AppVersionInfo(bundle: .main).distribution, expected)
    }

    func testVersionInfoReadsFromBundle() {
        // Whatever the test host reports, reading must not crash and must
        // yield a non-empty display string.
        XCTAssertFalse(AppVersionInfo(bundle: .main).displayString.isEmpty)
    }

    @MainActor
    func testSplashViewRenders() {
        let view = SplashView(version: AppVersionInfo(shortVersion: "1.2.3", build: "7"))
        let controller = NSHostingController(rootView: view)
        XCTAssertNotNil(controller.view)
    }

    @MainActor
    func testLaunchGateStartsUnset() {
        // Guards against the gate being accidentally pre-set, which would
        // silently suppress the splash for the whole session.
        XCTAssertFalse(SplashLaunchGate.hasPresented)
    }
}
