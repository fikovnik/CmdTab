// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CmdTab",
    platforms: [.macOS(.v13)],
    targets: [
        // Configuration values and keyboard state. No WindowServer connection.
        .target(
            name: "CmdTabConfig",
            dependencies: ["CmdTabModel"],
            path: "Sources/CmdTabConfig",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Window order, traversal, and geometry. No WindowServer connection.
        .target(
            name: "CmdTabModel",
            path: "Sources/CmdTabModel",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "CmdTab",
            dependencies: ["CmdTabConfig", "CmdTabModel"],
            path: "Sources/CmdTab",
            // AppKit and AX state use the main actor. File writes and commands use worker queues.
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
            linkerSettings: [.unsafeFlags(["-F", "/System/Library/PrivateFrameworks",
                                           "-framework", "SkyLight"])]
        ),
        .testTarget(
            name: "CmdTabTests",
            dependencies: ["CmdTab"],
            path: "Tests/CmdTabTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmdTabConfigTests",
            dependencies: ["CmdTabConfig"],
            path: "Tests/CmdTabConfigTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmdTabModelTests",
            dependencies: ["CmdTabModel"],
            path: "Tests/CmdTabModelTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
