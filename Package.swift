// swift-tools-version: 6.0
import PackageDescription

// Swift 6 language mode turns on complete strict concurrency checking. The upcoming features
// below are stricter checks that Swift 6 mode does not enable by default.
let strictSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "SwiftMCPAppHost",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),   // so `swift test` runs on the Mac
    ],
    products: [
        .library(name: "SwiftMCPAppHost", targets: ["SwiftMCPAppHost"]),
    ],
    // No dependencies, by design.
    targets: [
        .target(name: "SwiftMCPAppHost", swiftSettings: strictSettings),
        .testTarget(
            name: "SwiftMCPAppHostTests",
            dependencies: ["SwiftMCPAppHost"],
            swiftSettings: strictSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
