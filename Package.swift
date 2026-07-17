// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "brainmaxxing",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "DigestCore", targets: ["DigestCore"]),
        .executable(name: "digest-cli", targets: ["DigestCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "DigestCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .executableTarget(
            name: "DigestCLI",
            dependencies: [
                "DigestCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
