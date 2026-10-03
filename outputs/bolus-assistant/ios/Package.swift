// swift-tools-version: 5.9
import PackageDescription

// BolusCore: deterministic, platform-independent logic of the local-first app
// (bolus engine, safety layer, IOB, cycle, analytics, food, reports, backup).
// It depends only on Foundation, so `swift test` runs on macOS and Linux.
let package = Package(
    name: "BolusCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "BolusCore", targets: ["BolusCore"])],
    targets: [
        .target(name: "BolusCore"),
        .testTarget(
            name: "BolusCoreTests",
            dependencies: ["BolusCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
