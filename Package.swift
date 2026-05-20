// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Clacal",
    platforms: [.macOS(.v15)],
    products: [
        .executable(
            name: "clacal-cli",
            targets: [ "ClacalCLI" ]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.7.1"),
    ],
    targets: [
        .executableTarget(
            name: "Clacal",
            dependencies: [
                .target(name: "ClacalCore"),
            ]
        ),
        .testTarget(
            name: "ClacalTests",
            dependencies: [
                "Clacal",
                .target(name: "ClacalCore"),
            ]
        ),
        .target(name: "ClacalCore"),
        .executableTarget(
            name: "ClacalCLI",
            dependencies: [ "ClacalCore", .product(name: "ArgumentParser", package: "swift-argument-parser"),]
        ),
    ]
)
