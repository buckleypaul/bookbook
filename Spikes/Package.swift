// swift-tools-version: 6.2
// Throwaway Phase 0 spike package (implementation-plan.md §4). Not part of the app.
// The recorder and redaction code move into BBNet's test support in Phase 2.
import PackageDescription

let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "Spikes",
    platforms: [.macOS("27.0")],
    targets: [
        // Shared spike infrastructure: HTTP client, multipart, fixture recorder, spend guard, test images.
        .target(name: "SpikeKit", swiftSettings: strict),
        // Offline tests of SpikeKit (run in CI-like mode, no network).
        .testTarget(name: "SpikeKitTests", dependencies: ["SpikeKit"], swiftSettings: strict),
        // Live OpenAI spikes SP-1…SP-7. Suite must be named LiveProviderTests (scripts/live-tests.sh).
        .testTarget(name: "OpenAISpikeTests", dependencies: ["SpikeKit"], swiftSettings: strict),
        // Local, no-cost spikes SL-1 and SL-2 (§4.3).
        .testTarget(name: "LocalSpikeTests", dependencies: ["SpikeKit"], swiftSettings: strict),
        // SL-3: throwaway SwiftUI app for WindowGroup(for:) behaviour.
        .executableTarget(name: "SL3WindowGroupApp", swiftSettings: strict),
    ]
)
