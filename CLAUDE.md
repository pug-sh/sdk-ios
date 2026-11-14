# CLAUDE.md

Guidance for Claude Code when working in this repository: the Pug analytics SDK for iOS, written in
Swift and distributed through Swift Package Manager as the `Pug` product of `pug-sh/sdk-ios`.

## Scope

The SDK tracks events, identifies users, manages tracking consent and delivers batches to the Pug
API. Push notifications and device registration (`sdk.devices.v1`, `IdentifyRequest.device_id`) are
out of scope.

`../sdk-android` (`pug-sh/sdk-android`) is the reference implementation: its README is the
behavioral contract, and its CLAUDE.md invariants apply here unless this file says otherwise. Storage
keys (`__pug_<projectId>_<name>__`), persisted JSON shapes, limits, retry rules, the permanent-error
set, consent semantics and identify linking are shared across Pug's SDKs: port them, do not
redesign them. Where the SDKs disagree, follow Android, which follows sdk-web.

## Setup

Swift 6 from Xcode 16 or newer, or from swift.org on Linux. Every other tool comes through SwiftPM at
a version a `Package.resolved` pins:

- swift-protobuf, a test-only dependency of `Package.swift`, supplies the runtime of the reference
  messages and the `protoc` and `protoc-gen-swift` that `make protos` builds (protoc from source,
  a few minutes the first time). It is pinned to 1.37.0, the last release Swift 6.0 can load: a
  newer one in `Package.resolved` would stop Xcode 16.0 from loading the package at all. Apps never
  resolve it, since SwiftPM skips the test-only dependencies of a dependency.
- `Tools/` is a separate package for the development tools, never a dependency of `Pug`. It pins
  SwiftLint (SwiftLintPlugins, the official binary), which the Makefile runs through its command
  plugin, and holds gen-track and api-dump.
- swift-format is the toolchain's `swift format`. CI's Swift 6.2 formats; another version can format
  differently.
- buf is needed only to re-vendor `proto/` (`brew install bufbuild/buf/buf`).

On a Linux host without Swift, `make docker-<target>` runs a Makefile target in the CI job's
container (`Tools/linux.Dockerfile`, the Swift 6.2 image plus make): `make docker-check`,
`make docker-fmt`, `make docker-ci`. The UIKit code compiles there too, in xtool's container
(`Tools/xtool.Dockerfile`, Swift 6.4): `make xtool-sdk XIP=/path/to/Xcode.xip` installs the Darwin
Swift SDK into `~/.swiftpm` once, from an Xcode.xip downloaded with an Apple ID (xtool 1.24's docs
name 27.1; 27.2 works too); then `make xtool-build-ios` builds the SDK for an iOS device and the
tests for the simulator, which it cannot run, and typechecks the sample app's sources.

## Commands

```bash
make check       # verify-version + swift format lint + SwiftLint + em dash check + build + api-check
                 # + tests, warnings as errors
make fmt         # swift format, in place
make api-dump    # rewrite api/Pug.api after a change to the public API, to review and commit with it
make protos      # regenerate from proto/: the reference messages, Tests/PugTests/Resources/events.binpb
                 # and the typed track API (make typed-track)
make ci          # protos + check-codegen + check: what the Linux CI job runs
make build-ios   # macOS: the SDK for an iOS device, warnings as errors
make check-ios   # macOS: build and tests on the Mac, build-ios, the sample app for the simulator, the
                 # tests on an iOS simulator, and under Thread Sanitizer
```

Work is done when `make check` passes, and `make check-ios` on a Mac. CI (`.github/workflows/ci.yml`)
runs `make docker-ci` on Linux, `make check-ios` on macOS 26, and under Xcode 16.0, the oldest Xcode
supported, builds the SDK for an iOS device with SwiftPM: the macOS 15 image no longer has the iOS
platform that xcodebuild needs for that Xcode.

A release is a tag `X.Y.Z` (no `v`), pushed once `sdkVersion` and the README's install line name
it. `.github/workflows/release.yml` then checks the tag against them, runs `check-proto-pin` and the
CI jobs on the tagged commit, and creates the GitHub release. SwiftPM serves the tag; nothing is
uploaded.

`proto/` is vendored from the Buf Schema Registry at the commit pinned in the `Makefile`, the same
as sdk-android's. Never edit it by hand: bump `PROTO_COMMIT`, run `make sync-protos protos` and
review the diff. `make check-proto-pin` proves `proto/` matches the pin.

## Layout

- `Sources/Pug/`: the SDK, module `Pug`, Swift 6 language mode. `Version.swift` holds `sdkVersion`
  (sent as `$sdkVersion` and in the User-Agent), which `make verify-version` checks the README's
  install line against. The rest ports `sh.pug.android` file by file.
- `Sources/Pug/Internal/Runtime/`: `Facade` is the state behind `Pug`: the running `Client`, and
  the last one's `Teardown`, which the next client waits for before it touches storage. A `Client`
  maps each call on the caller's thread and submits an op to its `OpQueue`, which runs ops in call
  order on the worker every client shares, once `ClientCore`, the worker-confined state, has
  restored what earlier launches stored. `destroy()` closes the queue with a final op that drains
  for at most 10 s; `drain(then:)` also completes on `dispose()`, so teardown finishes once,
  whichever comes first. `Configuration` is `Pug.Options` checked and resolved.
- `Sources/Pug/Internal/Platform/`: `Platform` is what the runtime takes from the device:
  `UIKitPlatform` on iOS, `FoundationPlatform` elsewhere. `AppLifecycleTracker` turns UIKit's
  notifications and the view controllers `ScreenTracker` hooks into the client's lifecycle, on the
  main thread. SwiftUI's `pugScreen(_:)` (`Sources/Pug/View+PugScreen.swift`) puts a
  `NamedScreenController` behind the view: UIKit tells that child view controller of the view's
  appearance, and it reports itself to `ScreenTracker`, so named screens share the view controllers'
  rules, sheets included, with the hooks off too. `AppLifecycleTracker`, `DeviceAutoProperties`,
  `DeviceModels` and `InstallSource` are plain Swift, which the Linux tests cover; the UIKit and
  SwiftUI files are `#if os(iOS)` or `#if canImport(SwiftUI)`, which only `make build-ios`,
  `make check-ios` and `make xtool-build-ios` compile.
- `Tests/PugTests/`: Swift Testing, mirroring sdk-android's `pug/src/test`. `Reference/` is
  generated by `make protos` and never edited; `check-codegen` fails on drift. `TestScheduler` runs
  virtual time as kotlinx-coroutines-test does: `advanceTime(by:)` stops short of the work due at the
  new time, which `runCurrent()` then runs. `HTTPTransportTests` answer requests with a `URLProtocol`
  stub (`StubServer`); Linux's FoundationNetworking traps when one redirects, so the refusal of
  redirects is checked at the session delegate. `FakePlatform` drives the app's lifecycle; tests
  that run what it posts to the main thread are `@MainActor`. `UIKitPlatformTests` runs on the iOS
  simulator only, without a host app, so `UIApplication` is absent there. Swift Testing logs every
  argument in full, and GitHub's runner takes minutes over one long line, so a large input is built
  in the test from a small argument, as `SHA256Tests` does with its million a's.
- `Sources/Pug/Generated/`: `Pug.Events`, `Pug.TrackNamespace` and `WellKnownEvents`, written by
  `Tools/gen-track` from a protoc descriptor set of `proto/common/events/v1`. Never edited: change the
  generator and run `make typed-track`. `WellKnownEventsTests` checks them against `events.binpb`.
- `Sources/Pug/PrivacyInfo.xcprivacy`: the privacy manifest, a resource of the target. It declares
  the data the SDK collects (product interaction, the user id, the anonymous id as a device id) and
  no required-reason API: update it when the SDK collects something new or starts calling one, such
  as `UserDefaults` or a file's dates.
- `api/Pug.api`: the public API, as `Tools/api-dump` renders the symbol graph of the module `build`
  compiled; `api-check` fails while it is out of date. Written by CI's Swift 6.2, since compilers
  print some declarations differently. Symbol graphs leave `@Sendable` out of closure types, so the
  file does not show it, and Linux has no SwiftUI, so it lacks `pugScreen(_:)`.
- `Examples/PugSample/`: the sample app, a reference for the developers who integrate the SDK, so
  it stays small: a UIKit app with a SwiftUI screen, using each API once. The extensive device
  checks belong to a test app of its own outside this repo, as `../sdk-android-testapp` is for
  Android. An Xcode 16 project with a synchronized folder, so files added to `PugSample/` need no
  project edit; the SDK is a local package (`../..`). `Sample.xcconfig` and the ignored
  `Local.xcconfig` reach the code through `Info.plist`. Only Xcode builds it (`make build-sample`);
  `make xtool-build-ios` typechecks its sources on Linux.
- `Tools/`: development tools, a package of its own: SwiftLint, gen-track and api-dump.
- `proto/`: vendored, see above.

## Invariants

- **Never crash the host app.** Swift traps cannot be caught, where Android catches `Throwable`.
  No `!`, `try!`, `as!`, `fatalError`, `precondition` or `unowned` (SwiftLint fails on each), and no
  unchecked conversion or arithmetic on host or stored values: `Int64(exactly:)`, the
  overflow-reporting operators, restored times range-checked first. `assert` is allowed, since
  release builds drop it. The only host-facing throw is `Pug.initialize` argument validation. Never
  read `Bundle.module`: SwiftPM's accessor for the privacy manifest's bundle traps when it is
  missing.
- **No runtime dependencies:** Foundation, UIKit, SwiftUI, Network and os only, hence a hand-rolled
  protobuf codec and JSON writer. Never add a dependency to the `Pug` target.
- **Never block the caller's thread, and no I/O on the main thread.**
- **No host code under a lock:** `Locked` is an `NSLock`, which is not reentrant, and a host
  `Logger` or callback may call back into Pug. Log, call the platform and run callbacks once the
  lock is released.
- **Deterministic bytes:** dictionary order is random per process, so sort keys (UTF-16 code-unit
  order, as protobuf-java and Android: `sortedByUTF16Key()`) before encoding.
- **Wire pitfalls:** a selected oneof member is written even when it holds a default value; empty ids
  are omitted (edition 2023 explicit presence). `WireTests` compares the codec with swift-protobuf,
  byte for byte where Swift's key order agrees with UTF-16 order (ASCII keys) and decoded otherwise;
  keep it passing.
- **Unicode:** Swift strings are always valid Unicode; truncation cuts on Unicode scalar boundaries
  through the UTF-8 view, matching Android's code-point cut. Prefixes the server checks (`$`,
  `cookieless-`) compare UTF-8 bytes with `hasUTF8Prefix`, since `hasPrefix` compares characters.
- **Foundation differs by platform:** classify `NSNumber` before Swift casts (`as? Bool` matches 0
  and 1); stored JSON is read through `StoredJSON`, and URLSession errors by `NSError` domain and
  code, since Linux does not bridge them to `URLError`. Darwin and Linux Foundation bridge
  differently, which is why the tests run on both.
- **Transport contract:** permanent = invalid_argument, not_found, already_exists,
  permission_denied, failed_precondition, unimplemented, unauthenticated. A 2xx that is not protobuf
  is transient (captive portals). Answers arrive on any thread: `EventDispatcher` hops them to the
  worker and re-checks `disposed` and the purge generation before touching the queue. A timer
  cancels each request at its deadline, since URLSession's timeouts measure idleness; bodies are
  read up to 64 KiB, and redirects are refused so the API key stays with the endpoint's host.
- **Unreadable storage is a failure, never an absent key** (where Android reads it as absent): iOS
  can launch an app before the first unlock after a reboot, when its files cannot be read.
  `FileStorage` throws, and the client waits for the unlock (`whenProtectedDataAvailable`) before it
  restores; a file still unreadable then moves the client to memory (`SafeStorage`) and
  `InstallTracker` skips detection, so no launch mints a new identity or a false `app_install` over
  the stored ones. Consent is read first, so a failed read means a stored choice exists: it is
  denied until the user chooses, since it may be an opt-out.
- **UIKit is main-thread only, and app extensions lack `UIApplication.shared`:** naming it breaks
  the build of an extension that links Pug, so `UIKitPlatform.application()` looks it up at
  runtime, nil in an `.appex`, which tracks no automatic events. What the worker needs from UIKit is
  read on the main thread into `DeviceSnapshot`. The view controller hooks call UIKit's own
  implementation first and report only on the main thread.
- **Logging:** `os.Logger` redacts dynamic strings, so the SDK logs its messages as public, and they
  never contain property values or traits.

## Conventions

- swift-format with `.swift-format` (2 spaces, 120 columns). Run `make fmt` before committing.
- Every public type is nested in `enum Pug`.
- No comments that restate code. Comment only a non-obvious why: a protocol quirk, a workaround, a
  deliberate design choice.
- No em dashes in code, comments or docs; `make lint` fails on them. `proto/` and the generated
  reference messages are exempt.
- Commit messages describe the change itself, in the `feat:` / `fix:` / `build:` style of
  sdk-android's history.
