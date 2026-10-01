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
                // `--report`, the Write Diagnostics menu item and the trace on
                // a Space change are only in debug builds. They ask every app
                // over AX and write window titles to a file.
                .define("DIAGNOSTICS", .when(configuration: .debug)),
            ],
            linkerSettings: [.unsafeFlags(["-F", "/System/Library/PrivateFrameworks",
                                           "-framework", "SkyLight"])]
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
