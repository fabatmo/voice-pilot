// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoicePilot",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "VoicePilot",
            path: "Sources/VoicePilot",
            resources: [.copy("../../Resources")]
        )
    ]
)
