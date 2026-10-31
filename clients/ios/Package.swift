// swift-tools-version:5.9
import PackageDescription

// ZeroSumFFI and the XCFramework are produced by scripts/build-ios-core.sh from
// crates/ffi-uniffi. Run it before building or testing.
let package = Package(
    name: "ZeroSumKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ZeroSumKit", targets: ["ZeroSumKit"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .binaryTarget(name: "zero_sum_ffi_uniffiFFI", path: "Frameworks/zero_sum_ffi_uniffiFFI.xcframework"),
        .target(name: "ZeroSumFFI", dependencies: ["zero_sum_ffi_uniffiFFI"]),
        .target(
            name: "ZeroSumKit",
            dependencies: ["ZeroSumFFI", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(name: "ZeroSumKitTests", dependencies: ["ZeroSumKit"]),
    ]
)
