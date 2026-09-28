// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CmdTab",
    platforms: [.macOS(.v13)],
    targets: [
        // Chord parsing, the config file and the action table. Deliberately
        // free of AppKit and of private SPI, so the parts most worth testing
        // can be tested without a running app or a live WindowServer.
        .target(
            name: "CmdTabConfig",
            path: "Sources/CmdTabConfig",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "CmdTab",
            dependencies: ["CmdTabConfig"],
            path: "Sources/CmdTab",
            // Everything in this app is main-thread-only by construction (event
            // tap callback, AX, AppKit). Swift 6 mode makes the compiler hold
            // that invariant instead of the comments.
            swiftSettings: [
                .swiftLanguageMode(.v6),
                // `--report`, the Write Diagnostics menu item and the
                // Space-change auto-trace are debug-only: they walk every app
                // over the Accessibility API and print window titles.
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
    ]
)
