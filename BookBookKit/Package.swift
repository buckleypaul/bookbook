// swift-tools-version: 6.2
// BookBookKit: every BookBook module as a library target in one local package
// (implementation-plan.md P-1). The dependency graph is exactly architecture.md §3.
import PackageDescription

let settings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
    .treatAllWarnings(as: .error),
]

let collections: Target.Dependency = .product(name: "Collections", package: "swift-collections")
let snapshots: Target.Dependency = .product(name: "SnapshotTesting", package: "swift-snapshot-testing")

let modules = ["BBModel", "BBStore", "BBLayout", "BBNet", "BBAICore", "BBAI", "BBOpenAI", "BBGemini", "BBExport", "BBUI"]

let package = Package(
    name: "BookBookKit",
    platforms: [.macOS("27.0")],
    products: modules.map { .library(name: $0, targets: [$0]) },
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections", exact: "1.7.5"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", exact: "1.19.7"),
    ],
    targets: [
        // Value types, IDs, schema versions, derived queries. Foundation only, no I/O.
        .target(name: "BBModel", dependencies: [collections], swiftSettings: settings),
        // Package I/O, journal, library, migrations, image store, keychain. Bundles style/template presets.
        .target(name: "BBStore", dependencies: ["BBModel"], resources: [.copy("Resources/Presets"), .copy("Resources/SampleBook")],
                swiftSettings: settings),
        // Geometry, page order, TextKit 2 layout, PageRenderer. AppKit only for TextKit and fonts; no views.
        .target(name: "BBLayout", dependencies: ["BBModel"], swiftSettings: settings),
        // HTTP client, multipart, SSE. Redacts Authorization / x-goog-api-key.
        .target(name: "BBNet", swiftSettings: settings),
        // Provider protocols and request/response types shared by BBAI and the adapters (A §3, §7.2).
        .target(name: "BBAICore", dependencies: ["BBModel"], swiftSettings: settings),
        // Queue, context assembly, cost, errors, catalog. Bundles ModelCatalog.json, PriceList.json, prompts.
        .target(
            name: "BBAI",
            dependencies: ["BBAICore", "BBModel", collections],
            resources: [.copy("Resources/ModelCatalog.json"), .copy("Resources/PriceList.json"), .copy("Resources/Prompts"),
                        .copy("Resources/SensitiveTerms.json")],
            swiftSettings: settings
        ),
        .target(name: "BBOpenAI", dependencies: ["BBAICore", "BBNet"], swiftSettings: settings),
        .target(name: "BBGemini", dependencies: ["BBAICore", "BBNet"], swiftSettings: settings),
        // PDF, booklet, upscale, preflight.
        .target(name: "BBExport", dependencies: ["BBLayout", "BBModel"], swiftSettings: settings),
        // SwiftUI features, AppKit canvas, view models.
        .target(name: "BBUI", dependencies: ["BBExport", "BBAI", "BBAICore", "BBStore", "BBLayout", "BBModel"], swiftSettings: settings),

        // Test-only helpers (live-test gate, bundled test font). Never linked into the app.
        .target(name: "BBTestSupport", resources: [.copy("Resources/Fonts")], swiftSettings: settings),

        .testTarget(name: "BBModelTests", dependencies: ["BBModel", "BBTestSupport"], swiftSettings: settings),
        .testTarget(
            name: "BBStoreTests", dependencies: ["BBStore", "BBTestSupport"],
            resources: [.copy("Fixtures")], swiftSettings: settings
        ),
        .testTarget(
            name: "BBLayoutTests", dependencies: ["BBLayout", "BBTestSupport", snapshots],
            exclude: ["__Snapshots__"], swiftSettings: settings
        ),
        .testTarget(name: "BBNetTests", dependencies: ["BBNet", "BBTestSupport"], swiftSettings: settings),
        .testTarget(name: "BBAICoreTests", dependencies: ["BBAICore", "BBTestSupport"], swiftSettings: settings),
        .testTarget(name: "BBAITests", dependencies: ["BBAI", "BBTestSupport", snapshots], swiftSettings: settings),
        // Holds the LiveProviderTests suite (implementation-plan.md §2.3).
        .testTarget(
            name: "BBOpenAITests", dependencies: ["BBOpenAI", "BBTestSupport"],
            resources: [.copy("Fixtures")], swiftSettings: settings
        ),
        .testTarget(name: "BBGeminiTests", dependencies: ["BBGemini", "BBTestSupport"], swiftSettings: settings),
        .testTarget(
            name: "BBExportTests", dependencies: ["BBExport", "BBTestSupport", snapshots],
            exclude: ["__Snapshots__"], swiftSettings: settings
        ),
        .testTarget(name: "BBUITests", dependencies: ["BBUI", "BBAI", "BBAICore", "BBTestSupport", snapshots], swiftSettings: settings),
        .testTarget(name: "BBTestSupportTests", dependencies: ["BBTestSupport"], swiftSettings: settings),
    ]
)
