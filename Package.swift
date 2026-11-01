// swift-tools-version: 6.0

import PackageDescription

let swiftSettings: [SwiftSetting] = [.enableUpcomingFeature("ExistentialAny")]

let package = Package(
    name: "Pug",
    platforms: [.iOS(.v15), .macCatalyst(.v15), .macOS(.v12)],
    products: [
        .library(name: "Pug", targets: ["Pug"])
    ],
    dependencies: [
        // Test-only, so apps never resolve it: the runtime of the reference messages the wire tests
        // check the SDK's own codec against, and the protoc and protoc-gen-swift that `make protos`
        // generates them with. 1.37 is the last release Swift 6.0 can load.
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.37.0")
    ],
    targets: [
        .target(name: "Pug", swiftSettings: swiftSettings),
        .testTarget(
            name: "PugTests",
            dependencies: ["Pug", .product(name: "SwiftProtobuf", package: "swift-protobuf")],
            swiftSettings: swiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
