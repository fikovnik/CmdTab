// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CmdTab",
    platforms: [.macOS(.v13)],
    targets: [
        // Chord parsing, the config file and the action table. No AppKit and
        // no private API. Thus, tests can run it without a WindowServer.
        .target(
            name: "CmdTabConfig",
            path: "Sources/CmdTabConfig",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The window and Space model: pure logic, no AppKit, no private API.
        // Thus, tests can run it without a WindowServer.
        .target(
            name: "CmdTabModel",
            path: "Sources/CmdTabModel",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "CmdTab",
            dependencies: ["CmdTabConfig", "CmdTabModel"],
            path: "Sources/CmdTab",
            // All code in the app runs on the main thread: the event tap
            // callback, AX and AppKit. The Swift 6 mode makes the compiler
            // check this.
            swiftSettings: [
                .swiftLanguageMode(.v6),
                // Debug builds enable logging by default and support the
                // optional full report on each Space change. Release builds
                // enable diagnostic logging only through the menu setting.
                .define("DIAGNOSTICS", .when(configuration: .debug)),
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
