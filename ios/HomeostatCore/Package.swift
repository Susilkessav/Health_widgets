// swift-tools-version: 6.0
// HealthKit-independent core of the Homeostat iPhone app: canonical models,
// normalization, the durable local store, and the import and sync engines.
// The app target adds HealthKit, Keychain and SwiftUI on top.
import PackageDescription

let package = Package(
    name: "HomeostatCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "HomeostatCore", targets: ["HomeostatCore"])],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")],
    targets: [
        .target(name: "HomeostatCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        // Fixtures are read from the source tree (see TestSupport.swift) so the
        // cross-language golden files can be regenerated in place.
        .testTarget(name: "HomeostatCoreTests", dependencies: ["HomeostatCore"], exclude: ["Fixtures"]),
    ],
    swiftLanguageModes: [.v5]
)
