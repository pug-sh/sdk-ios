# Pug iOS SDK

Native Swift SDK for [Pug](https://pug.sh) analytics on iOS: event tracking, identity, sessions,
consent, and batched delivery that survives restarts and bad networks.

**In development:** not usable yet. The first release will be 0.1.0.

- iOS and iPadOS 15 or newer, Mac Catalyst included. Xcode 16 or newer.
- Swift Package Manager only. No runtime dependencies.

## Install

Once 0.1.0 is tagged, add the package in Xcode (File > Add Package Dependencies) or in
`Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/pug-sh/sdk-ios.git", from: "0.1.0"),
],
```

## License

[MIT](LICENSE)
