// swift-tools-version: 6.0
import PackageDescription

// ponytail: language mode 5 on purpose. Swift 6 strict concurrency would force
// @MainActor/@Sendable annotations through every AppKit callback in this app for
// zero benefit at this size. Move to .v6 if the app ever grows real concurrency.
let swiftSettings: [SwiftSetting] = [.swiftLanguageMode(.v5)]

// ponytail: XFlowChecks is an executable, not a .testTarget. This machine has
// Command Line Tools only, where neither XCTest nor swift-testing exists, so
// `swift test` cannot run. Assert-based checks give the same red-green cycle
// with zero frameworks. Switch to a real .testTarget if full Xcode is installed.
let package = Package(
    name: "XFlow",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "XFlowCore", swiftSettings: swiftSettings),
        .executableTarget(
            name: "XFlow",
            dependencies: ["XFlowCore"],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "XFlowChecks",
            dependencies: ["XFlowCore"],
            swiftSettings: swiftSettings
        ),
    ]
)
