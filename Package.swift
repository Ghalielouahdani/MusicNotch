// swift-tools-version: 6.2
import PackageDescription

// The Command Line Tools ship a stale manifest API without `.macOS(.v15)` or
// `.defaultIsolation`, so those are spelled as a version string and compiler flags.
let package = Package(
    name: "MusicNotch",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(
            name: "MusicNotch",
            path: "Sources/MusicNotch",
            swiftSettings: [
                .unsafeFlags(["-default-isolation", "MainActor"]),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        )
    ]
)
