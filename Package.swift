// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeStats",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeStats",
            path: "Sources/ClaudeStats",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ClaudeStatsTests",
            dependencies: ["ClaudeStats"],
            path: "Tests/ClaudeStatsTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
