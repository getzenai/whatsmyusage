// swift-tools-version: 6.0
import PackageDescription

// ai_usage_bar is a single package:
//
//   UsageBarCore — models, cookie extraction, per-provider translators (all testable)
//   UsageBar     — the menu bar app (assembled into WhatsMyUsage.app by
//                  Scripts/make-app-bundle.sh; no Xcode project)
//
// Everything that can be tested lives in UsageBarCore. The app stays thin so
// `swift test` covers the behaviour that decides what the bar shows.
let package = Package(
    name: "ai_usage_bar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UsageBarCore", targets: ["UsageBarCore"]),
        .executable(name: "UsageBar", targets: ["UsageBarApp"]),
    ],
    dependencies: [
        // Swift Testing ships inside Xcode, but not the standalone Command Line
        // Tools. Without this, `swift test` fails with "no such module 'Testing'"
        // (or a missing `_TestingInternals`) on a machine that has no Xcode.
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "0.10.0"),
    ],
    targets: [
        .target(name: "UsageBarCore"),
        .executableTarget(name: "UsageBarApp", dependencies: ["UsageBarCore"]),
        .testTarget(
            name: "UsageBarCoreTests",
            dependencies: [
                "UsageBarCore",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
