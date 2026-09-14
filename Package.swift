// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PrefixBoundLedger",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PrefixBoundLedger", targets: ["PrefixBoundLedger"])
    ],
    targets: [
        .target(name: "PrefixBoundLedger", path: "Sources/PrefixBoundLedger"),
        .testTarget(
            name: "PrefixBoundLedgerTests",
            dependencies: ["PrefixBoundLedger"],
            path: "Tests/PrefixBoundLedgerTests"
        )
    ]
)
