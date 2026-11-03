// swift-tools-version:5.9
// The Swift half of garage-ocr's `vision-documents` feature, for Cargo builds: build.rs links it through
// swift-rs's SwiftLinker. Bazel builds the same source as //rust/garage-ocr:GarageOCRDocuments instead.

import PackageDescription

let package = Package(
    name: "GarageOCRDocuments",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GarageOCRDocuments", type: .static, targets: ["GarageOCRDocuments"]),
    ],
    dependencies: [
        // The same version as the swift-rs crate in rust/Cargo.lock and ext/swift_rs.
        .package(url: "https://github.com/Brendonovich/swift-rs", exact: "1.0.9"),
    ],
    targets: [
        .target(
            name: "GarageOCRDocuments",
            dependencies: [.product(name: "SwiftRs", package: "swift-rs")]
        ),
    ]
)
