// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "BolusCore", platforms: [.macOS(.v13), .iOS(.v17)], products: [.library(name: "BolusCore", targets: ["BolusCore"])], targets: [.target(name: "BolusCore"), .testTarget(name: "BolusCoreTests", dependencies: ["BolusCore"])])
