// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AudioScribeApp",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AudioScribeApp", targets: ["AudioScribeApp"])
    ],
    targets: [
        .executableTarget(
            name: "AudioScribeApp",
            path: "Sources/AudioScribeApp"
        )
    ]
)
