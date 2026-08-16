// swift-tools-version: 6.0
import PackageDescription

// WhatsMyUsage is a single package:
//
//   UsageBarCore — models, cookie extraction, per-provider translators, log, CLI queries
//   UsageBar     — the menu bar app (assembled into WhatsMyUsage.app by
//                  Scripts/make-app-bundle.sh; no Xcode project)
//   whatsmyusage — read-only CLI over usage-log.sqlite and app UserDefaults
//                  (no Keychain, no network)
//
// Everything that can be tested lives in UsageBarCore. The app stays thin so
// `swift test` covers the behaviour that decides what the bar shows.
let package = Package(
    name: "WhatsMyUsage",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UsageBarCore", targets: ["UsageBarCore"]),
        .executable(name: "UsageBar", targets: ["UsageBarApp"]),
        .executable(name: "whatsmyusage", targets: ["WhatsMyUsageCLI"]),
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
        .executableTarget(name: "WhatsMyUsageCLI", dependencies: ["UsageBarCore"]),
        .testTarget(
            name: "UsageBarCoreTests",
            dependencies: [
                "UsageBarCore",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
