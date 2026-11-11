// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MusicNotch",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(
            name: "MusicNotch",
            path: "Sources/MusicNotch"
        )
    ]
)
