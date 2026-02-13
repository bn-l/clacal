// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ClaudeCodeUsage",
    platforms: [.macOS(.v15)],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "ClaudeCodeUsage",
            dependencies: []
        ),
        .testTarget(
            name: "ClaudeCodeUsageTests",
            dependencies: [
                "ClaudeCodeUsage",
            ]
        ),
    ]
)
