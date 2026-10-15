// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "OpenFlo",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7")
    ],
    targets: [
        .executableTarget(
            name: "OpenFlo",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/OpenFlo",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
