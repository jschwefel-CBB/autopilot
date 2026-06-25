// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "autopilot",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacOSDriver", targets: ["MacOSDriver"]),
        .executable(name: "autopilot", targets: ["autopilot"]),
        .executable(name: "AutopilotMCP", targets: ["AutopilotMCP"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(path: "../autopilot-core"),
    ],
    targets: [
        .target(
            name: "MacOSDriver",
            dependencies: [
                .product(name: "AutopilotCore", package: "autopilot-core"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "autopilot",
            dependencies: [
                "MacOSDriver",
                .product(name: "AutopilotCore", package: "autopilot-core"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "AutopilotMCPKit",
            dependencies: [
                "MacOSDriver",
                .product(name: "AutopilotCore", package: "autopilot-core"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AutopilotMCP",
            dependencies: ["AutopilotMCPKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AutopilotCoreTests",
            dependencies: [
                "MacOSDriver",
                .product(name: "AutopilotCore", package: "autopilot-core"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AutopilotMCPKitTests",
            dependencies: ["AutopilotMCPKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
