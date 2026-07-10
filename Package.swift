// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MandelbrotExplorer",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "MandelbrotExplorer",
            path: "Sources/MandelbrotExplorer",
            resources: [
                .copy("Rendering/Shaders.metal")
            ]
        )
    ]
)
