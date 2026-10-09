// swift-tools-version: 6.0
// HealthKit-independent core of the Homeostat iPhone app: canonical models,
// normalization, the durable local store, and the import and sync engines.
// The app target adds HealthKit, Keychain and SwiftUI on top.
import PackageDescription

let package = Package(
    name: "HomeostatCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HomeostatCore", targets: ["HomeostatCore"]),
        // For the widget extension: WidgetState, the App Group cache and the
        // display policy. No GRDB, no queue, no health payloads.
        .library(name: "HomeostatShared", targets: ["HomeostatShared"]),
        // The pure engine, for the widget's own recalculation (M3). No GRDB.
        .library(name: "HomeostatEngine", targets: ["HomeostatEngine"]),
    ],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")],
    targets: [
        .target(name: "HomeostatShared"),
        .target(name: "HomeostatEngine", dependencies: ["HomeostatShared"]),
        .target(name: "HomeostatCore", dependencies: ["HomeostatShared", "HomeostatEngine",
                                                      .product(name: "GRDB", package: "GRDB.swift")]),
        // Fixtures are read from the source tree (see TestSupport.swift) so the
        // cross-language golden files can be regenerated in place.
        .testTarget(name: "HomeostatCoreTests", dependencies: ["HomeostatCore", "HomeostatEngine"], exclude: ["Fixtures"]),
        .testTarget(name: "HomeostatSharedTests", dependencies: ["HomeostatShared"], exclude: ["Fixtures"]),
    ],
    swiftLanguageModes: [.v5]
)
