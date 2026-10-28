// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Cadre",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Cadre",
            path: "Sources/Cadre",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CadreTests",
            dependencies: ["Cadre"],
            path: "Tests/CadreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
