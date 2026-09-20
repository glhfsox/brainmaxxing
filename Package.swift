// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "brainmaxxing",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "DigestCore", targets: ["DigestCore"]),
        .executable(name: "digest-cli", targets: ["DigestCLI"]),
        .executable(name: "DigestMCP", targets: ["DigestMCP"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", exact: "0.12.1"),
        // Already required by swift-sdk; named here because DigestMCP's transport wrapper must spell `Logger`.
        .package(url: "https://github.com/apple/swift-log", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "DigestCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "MCP", package: "swift-sdk"),
            ],
            resources: [.copy("Prompts")]
        ),
        .executableTarget(
            name: "DigestCLI",
            dependencies: [
                "DigestCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // MCP server over stdio.
        .executableTarget(
            name: "DigestMCP",
            dependencies: ["DigestCore", .product(name: "MCP", package: "swift-sdk"), .product(name: "Logging", package: "swift-log")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
