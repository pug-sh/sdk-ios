// swift-tools-version: 6.0

import PackageDescription

// The development tools, pinned by this package's Package.resolved and kept out of the SDK's
// manifest. SwiftLint runs through its command plugin (`make lint`); gen-track writes the typed track
// API from the event protos (`make typed-track`); api-dump writes the public API that api/Pug.api
// records (`make api-dump`).
let package = Package(
  name: "PugTools",
  platforms: [.macOS(.v13)],
  dependencies: [
    .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins.git", exact: "0.65.1"),
    // The release the SDK's tests pin, whose protoc writes the descriptor set gen-track reads.
    .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.37.0"),
  ],
  targets: [
    .executableTarget(name: "api-dump"),
    .executableTarget(
      name: "gen-track",
      dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")]
    ),
  ]
)
