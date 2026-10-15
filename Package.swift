// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "OpenFlo",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "OpenFlo", path: "Sources/OpenFlo", swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
