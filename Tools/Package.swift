// swift-tools-version: 6.0

import PackageDescription

// The development tools, pinned by this package's Package.resolved and kept out of the SDK's
// manifest. SwiftLint runs through its command plugin: `make lint`.
let package = Package(
    name: "PugTools",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins.git", exact: "0.65.1")
    ],
    targets: []
)
