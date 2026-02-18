// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SonoTwinApp",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SonoTwinApp", targets: ["SonoTwinApp"])
    ],
    targets: [
        .executableTarget(
            name: "SonoTwinApp",
            path: "Sources/SonoTwinApp"
        )
    ]
)
