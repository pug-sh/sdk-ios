# Pug iOS SDK

Native Swift SDK for [Pug](https://pug.sh) analytics on iOS: event tracking, identity, sessions,
consent, and batched delivery that survives restarts and bad networks.

- iOS and iPadOS 15 or newer, Mac Catalyst and iPad apps on a Mac included. Xcode 16 or newer;
  apps in the Swift 5 language mode can use it too, and Objective-C code through a Swift wrapper of
  its own.
- Swift Package Manager only. No runtime dependencies: Foundation, UIKit, SwiftUI, Network and os.
- Ships a privacy manifest. Needs no permission, entitlement or App Tracking Transparency prompt.

## Install

In Xcode, choose File > Add Package Dependencies, enter `https://github.com/pug-sh/sdk-ios` and add
the `Pug` library to your app's target. In a `Package.swift`:

```swift
dependencies: [
  .package(url: "https://github.com/pug-sh/sdk-ios.git", from: "0.1.0"),
],
targets: [
  .target(name: "YourApp", dependencies: [.product(name: "Pug", package: "sdk-ios")]),
],
```

## Quickstart

Call `Pug.initialize` once, in `application(_:didFinishLaunchingWithOptions:)` or, in a SwiftUI
app, in your `App`'s `init()`:

```swift
import Pug

do {
  try Pug.initialize(projectId: "your-project-id", options: Pug.Options(apiKey: "pub_your_public_key"))
} catch {
  assertionFailure("Pug was not started: \(error)")
}
```

Then track from anywhere:

```swift
Pug.track("checkout_started", properties: ["cartId": "c1", "total": 84.50])
Pug.track.addToCart(productId: "sku-1", price: 9.99, currency: "USD")
Pug.identify("user-42", traits: ["plan": "pro"])
```

From there the SDK tracks `app_open` and `app_close` as the app comes and goes, a `screen_view`
each time one of your view controllers appears on a different screen, and `app_install` or
`app_update` on the first launch of each app version.

Every call returns at once, can be made from any thread, and never throws: calls run in order on one
background thread, and failures are logged rather than raised. The one exception is
`Pug.initialize`, which throws `Pug.ConfigurationError` for a blank project id, an API key that is
not the project's public key (`pub_…`), or an endpoint that is not an http(s) URL with a host and no
query or fragment. Calls made before `Pug.initialize` are ignored with a warning, and so is a second
`Pug.initialize` until `Pug.destroy()`. `Pug.initialize` does no disk or network work on the calling
thread, so it is safe on the main thread at launch. The consent getters never wait either; see
[Tracking consent](#tracking-consent).

## Options

```swift
var options = Pug.Options(apiKey: "pub_your_public_key")
#if DEBUG
options.debug = true
#endif
options.batchMaxSize = 20
options.batchMaxWait = 10
options.defaultTrackingConsent = .denied
try Pug.initialize(projectId: "your-project-id", options: options)
```

| Option | Default | |
| ------ | ------- | - |
| `endpoint` | `https://api.pugs.dev` | Base URL of the Pug API. An `http` one needs an App Transport Security exception in your app's Info.plist, such as `NSAllowsLocalNetworking` for a server on your Mac. |
| `debug` | `false` | Logs debug messages: each event tracked, sent or dropped, and why. Warnings and errors are always logged. |
| `dryRun` | `false` | Builds and logs events without sending anything; `identify` is not sent either. Consent is unaffected. |
| `batchMaxSize` | `10` | Events go out in requests of up to this many (at most 1000): once that many are queued, or `batchMaxWait` after the first of them. |
| `batchMaxWait` | `5` | Seconds the first queued event waits for a full batch. |
| `batchMaxQueueSize` | `1000` | Beyond this many undelivered events, the oldest is dropped. |
| `sessionIdleTimeout` | 30 min | A session ends after this many seconds without events. |
| `sessionMaxDuration` | 24 h | A session ends this many seconds after it began. |
| `defaultTrackingConsent` | `.granted` | See [Tracking consent](#tracking-consent). |
| `persistTrackingConsent` | `true` | See [Tracking consent](#tracking-consent). |
| `autoOpenCloseEvents` | `true` | Tracks `app_open` and `app_close`, nothing else. |
| `autoScreenViews` | `true` | Tracks a `screen_view` each time one of your view controllers appears on a different screen. |
| `autoInstallEvents` | `true` | Tracks `app_install` and `app_update`. |
| `logger` | the system log | A `Pug.Logger` to receive the SDK's messages instead. |
| `storage` | files | A `Pug.Storage` to keep the SDK's state in instead; `Pug.MemoryStorage()` keeps nothing on the device. |

Each option is set on its own; the ones left out keep their defaults. Nothing here throws: a number
out of range is logged and replaced by its default, and a `batchMaxSize` above 1000 is capped.

## Tracking events

### Custom events

```swift
Pug.track("video_shared", properties: ["videoId": "v1", "network": "mastodon", "duration": 31.5])
Pug.track("order_completed", properties: ["orderId": "o-1"], options: Pug.TrackOptions(immediate: true))
```

An event kind may contain letters, digits, `_`, `.` and `-`; any other kind is dropped with a
warning. Property values map as follows:

| Value | Sent as |
| ----- | ------- |
| `String`, `Substring`, `Character`, an enum with `String` raw values (its raw value) | string, cut to 1024 UTF-8 bytes |
| `Bool` | boolean |
| `Int`, `Int64`, `UInt64` and the other integer types | integer; one beyond the signed 64-bit range as a string of its digits |
| `Double`, `Float`, `CGFloat`, `Decimal` | decimal; NaN and infinities are dropped |
| `NSNumber` | by what it holds: boolean, integer or decimal |
| `Date` | timestamp |
| arrays, dictionaries and sets | JSON text |
| `nil`, `Optional.none`, `NSNull` | left out |
| anything else, such as `UUID`, `URL` or another enum | its `String(describing:)`, cut to 1024 UTF-8 bytes |

A key starting with `$` is reserved for auto-properties and dropped with a warning. Properties are
read during the call, so the dictionary can be changed or reused as soon as `track` returns.

`Pug.TrackOptions(immediate: true)` sends the event on its own right away instead of with the next
batch; if that send fails it joins the queue for a retry. `Pug.TrackOptions(timestamp:)` sets when
the event happened, for an event recorded after the fact; a time before 1970 or after the year 9999
is logged and replaced by the time of the call.

### Well-known events

The events Pug knows, but those it tracks itself, have a typed method on `Pug.track`, generated from
the event schemas, that takes the event's properties as labeled arguments: required ones without a
default, optional ones defaulting to `nil`. Swift's argument labels keep two values of one type from
swapping places.

```swift
Pug.track.search(query: "trail shoes")
Pug.track.purchase(productId: "sku-1", amount: 89.0, currency: "USD", orderId: "o-1")
Pug.track.videoPlay(videoId: "v1", position: 1.5)
Pug.track.addToCart(
  productId: "sku-1",
  extras: ["coupon": "SPRING"],
  options: Pug.TrackOptions(immediate: true)
)
```

- `extras` carries further properties. An extra named like an argument is dropped with a warning
  when that argument is set.
- Durations are `TimeInterval` seconds, sent as text and rounded to the millisecond:
  `position: 1.5` sends `position: "1.5s"`.
- Values are sent as given: the schemas name and type the properties, but ranges and patterns are
  not enforced on the device.
- The events the SDK tracks itself have no method: `app_open`, `app_close`, `app_install`,
  `app_update` and `screen_view`. For a screen that is not a view controller, call `Pug.screen`.
  With the automatic events turned off, `Pug.track(Pug.Events.appOpen)` and the like still work.

The kinds are constants in `Pug.Events` (`Pug.Events.addToCart` is `"add_to_cart"`). Tracking a
well-known kind with `Pug.track(_:properties:)` works too, and a whole number given for a decimal
property is sent as a decimal (`"price": 10` arrives as `10.0`), so both paths fill the same column.

## Automatic events

| Event | When | Option |
| ----- | ---- | ------ |
| `app_open` | The app comes to the foreground: it becomes active, or enters the foreground, whichever comes first. | `autoOpenCloseEvents` |
| `app_close` | The app enters the background. Control Center, a call or a system alert in front of it is no exit. | `autoOpenCloseEvents` |
| `screen_view` | One of your view controllers appears on a different screen: `screenName` is its type's name, `screenClass` the module-qualified one. | `autoScreenViews` |
| `app_install` | The first launch with the SDK on this device, with `appVersion` and `installSource`. | `autoInstallEvents` |
| `app_update` | The first launch of a new app version, with `appVersion` and `previousVersion`. | `autoInstallEvents` |

The view controllers tracked are your app's own, from its executable or the frameworks it embeds,
whose parent is none or a navigation, tab bar, split or page view controller. Those containers,
UIKit's and SwiftUI's own view controllers (alerts and `UIHostingController` among them) and the
children of your own containers are skipped. A view controller that reappears with no other screen
in between, as after a share sheet it presented, is not tracked again. Several windows or scenes
count as one app.

`installSource` is `com.apple` for the App Store, `com.apple.testflight` for TestFlight and for the
builds Xcode installs, which have the same sandbox receipt, and `com.apple.simulator` on a
simulator.

When the app enters the background the SDK sends what is queued and writes its state to disk,
whatever `autoOpenCloseEvents` says, in a background task that ends once the sends settle, since iOS
may suspend the app from then on. A send that suspension cuts short is retried with the same event
ids, which the server deduplicates. An app that iOS launches in the background, as for a push, a
background fetch or a location update, tracks no `app_open`, `app_close` or `screen_view` until the
user opens it; the events you track meanwhile are sent as usual.

SwiftUI views are not view controllers, so name a SwiftUI screen with `pugScreen`, on the view the
screen shows, inside its `NavigationStack`:

```swift
NavigationStack {
  List(products) { product in
    NavigationLink(product.name) { ProductView(product: product) }
  }
  .pugScreen("Products")
}
```

It is tracked as a view controller is, with `autoScreenViews` off too: a `screen_view` with its
`screenName` and no `screenClass` when it appears on a different screen, and again when it comes
back after another. Dismissing a sheet makes the screen beneath it current again, and a new name is
a new screen. For a screen that is neither, call `Pug.screen("Level 3")`: it tracks a `screen_view`
unless that screen is already the current one.

Every event after a screen carries it as `$url` and the one before as `$referrer`. With
`autoScreenViews` off, view controllers are left alone entirely, so the screens are only the ones
you name.

`app_install` is the first launch with the SDK on the device, so when an update of your app adds
Pug, its existing users count as installs as they launch it. To see the first screen and `app_open`
of a launch, call `Pug.initialize` before the first scene connects, as above; called later, the SDK
tracks `app_open` at once and screens from the next one that appears.

## Identify, reset and sessions

```swift
Pug.identify("user-42", traits: ["email": "ada@example.com", "plan": "pro"])
```

`identify` attaches your own user id, and optional traits, to the profile. The first call links the
events tracked anonymously so far to that user. Traits may nest dictionaries and arrays. A blank id
or one starting with `cookieless-` (reserved by the server) is rejected with an error in the log.
`identify` is never retried; a failure is logged.

```swift
Pug.reset()          // On logout: a new anonymous id and session, and no user id.
Pug.rotateSession()  // End the session; the next event starts a new one.
Pug.flush()          // Send what is queued now, and write the SDK's state to disk.
Pug.destroy()        // Stop the SDK after a final flush of at most ten seconds.
```

Events queued before `reset()` keep the user they were tracked for, and `reset()` sends them without
waiting for the next batch. `destroy()` keeps identity, persisted consent and undelivered events for
the next `Pug.initialize`, which waits for the teardown to finish.

## Tracking consent

Consent is granted by default. To wait for the user's choice, start denied:

```swift
options.defaultTrackingConsent = .denied
```

```swift
Pug.whenConsentReady { if Pug.isConsentPending { showConsentBanner() } }

Pug.optInTracking()   // the user accepted
Pug.optOutTracking()  // the user declined
```

The choice is saved, so the banner shows only until the user answers, and an opt-out made in your
settings screen still holds after a restart.

- While consent is denied, events and `identify` are dropped, not kept for later.
- Opting out drops queued events unsent and removes the stored identity; opting in again starts a
  new anonymous identity.
- When the user opts in, the SDK tracks what consent held back: an `app_install` or `app_update` it
  could not track at launch and, if the app is in the foreground, `app_open` and a `screen_view` of
  the current screen. A consent banner on the first launch therefore loses none of them.
- The choice is stored and restored by the next `Pug.initialize`. If your app keeps the choice
  itself and calls `optInTracking()` or `optOutTracking()` on every launch, set
  `persistTrackingConsent = false`: the choice then lasts until `Pug.destroy()` or the process ends.
- `Pug.trackingConsent` is the consent in effect, `Pug.isTrackingEnabled` whether it is granted, and
  `Pug.isConsentPending` whether the user has yet to choose. They answer at once and never wait.
  Right after `Pug.initialize`, while the SDK is still reading the saved choice on its own thread,
  they answer "not known yet": `nil`, `false` and `true`. `Pug.whenConsentReady { … }` runs its
  closure on the main thread as soon as they answer for this user, on the main thread's next turn if
  they already do.

This consent is your app's own choice about analytics, as for a GDPR banner. App Tracking
Transparency is another matter, which Pug does not need: see [Privacy](#privacy).

## Auto-properties

Every event carries these alongside its own properties:

| Property | Value |
| -------- | ----- |
| `$projectId`, `$sdkVersion` | The project id passed to `Pug.initialize`, and this SDK's version. |
| `$platform` | `ios` |
| `$os`, `$osVersion` | `iOS`, on an iPad too, and the version, such as `26.1`. |
| `$device`, `$deviceModel` | The model, such as `iPhone 16 Pro`, or its identifier, such as `iPhone17,3`, for a model the SDK does not know yet. On a simulator, the simulated model. |
| `$deviceManufacturer` | `Apple` |
| `$deviceType` | `mobile`, or `desktop` for an iPhone or iPad app running on a Mac. |
| `$mobile` | `true` on an iPhone. |
| `$screenWidth`, `$screenHeight`, `$screenScale` | The screen in points, in the current orientation, and its scale. |
| `$locale`, `$timezone` | Such as `en-US`, from the user's preferred language and region, and `Europe/Berlin`. |
| `$appName`, `$appPackage`, `$appVersion`, `$appBuild` | From your app's Info.plist: `CFBundleDisplayName` (else `CFBundleName`), the bundle id, `CFBundleShortVersionString`, `CFBundleVersion`. |
| `$networkType` | `wifi`, `mobile`, `ethernet`, `other`, `none` or `unknown`; reading it needs no permission. |
| `$url`, `$referrer` | The current and previous screen. |

The device name is never collected. Locale, time zone and network are read for each event, the
screen and the OS version with each call made on the main thread and each time the app comes to the
foreground or a screen appears, the rest once per launch.

## Delivery and storage

- Events are queued and sent in batches, one request at a time. A request that fails for a reason
  that may pass (no network, a timeout, a server error, a captive portal) is retried with
  exponential backoff from `batchMaxWait` (at least a second) up to five minutes. A request the
  server rejects for good is dropped and logged as an error.
- Undelivered events, identity and consent are kept in files under the app's Application Support
  directory, in `<bundle id>/pug`, which is excluded from backups: they survive restarts but are not
  restored onto another device. Deleting the app deletes them, so a reinstall is a new install with
  a new anonymous id. Writes are grouped and land within a second, and at once when the app enters
  the background, on `Pug.flush()` and on `Pug.destroy()`.
- The files can be read once the device has been unlocked after a restart. When iOS launches the app
  in the background before that, the SDK starts at the unlock, and the calls made meanwhile run
  then.
- Requests are capped at 4 MiB. A single event over that, which only very large properties make, is
  dropped when tracked.
- Set `storage` to `Pug.MemoryStorage()` to keep nothing on the device, or to your own
  `Pug.Storage`. If your storage throws, the SDK falls back to memory until `Pug.destroy()` or the
  process ends. Throw from `string(forKey:)` when a value may exist but cannot be read: `nil` would
  start a new identity.

An app extension, such as a widget or a share extension, can use the SDK too: `track`, `identify`
and the rest work as in the app. It tracks no automatic events, and since it has a container of its
own, it has its own files and anonymous id.

## Logging

Messages go to the system log under the subsystem `sh.pug`, category `Pug`, which Xcode's console
and Console.app show: warnings and errors always, debug messages with `debug = true`. A
`Pug.Logger` receives them instead:

```swift
import OSLog

struct AppPugLogger: Pug.Logger {
  private let log = Logger(subsystem: "com.example.app", category: "Pug")

  func debug(_ message: String) {
    log.debug("\(message, privacy: .public)")
  }

  func warning(_ message: String, error: (any Error)?) {
    log.warning("\(message, privacy: .public)")
  }

  func error(_ message: String, error: (any Error)?) {
    log.error("\(message, privacy: .public)")
  }
}

options.logger = AppPugLogger()
```

It is called from any thread. Messages never contain event properties or traits, so they can be
logged as public.

## Privacy

The SDK ships a privacy manifest, which Xcode adds to your app's privacy report. It declares the
data the SDK collects for analytics, linked to the user and used for no tracking: product
interaction (the events), the user id that `identify` passes, and a device id, the anonymous id the
SDK gives each install. The SDK calls none of the APIs that need a declared reason.

It reads no advertising identifier, `identifierForVendor` or device name, and tracks no one across
other companies' apps, so it needs no App Tracking Transparency prompt. Your App Store privacy
answers still cover what your own events and traits carry, such as purchases or an email address.

## Sample app

[`Examples/PugSample`](Examples/PugSample) uses the SDK from UIKit and SwiftUI: custom and typed
events, view controllers tracked as screens and a SwiftUI screen named with `pugScreen`, identify,
reset and consent. Open `Examples/PugSample/PugSample.xcodeproj` in Xcode, run it on a simulator and
watch Xcode's console. It runs in dry run, logging events without sending them, until you set a
project in `Examples/PugSample/Local.xcconfig`, which Git ignores:

```
PUG_PROJECT_ID = your-project-id
PUG_API_KEY = pub_your_public_key
// Optional. In this file `//` starts a comment, so `$()` goes between a URL's slashes. The sample
// may use http, e.g. http:/$()/localhost:8080 from the simulator for a backend on the Mac.
PUG_ENDPOINT = https:/$()/api.pugs.dev
```

To run it on an iPhone, choose your team under the target's Signing & Capabilities, or set it in
`Local.xcconfig` to leave the project file as it is, with a bundle id of your own if Xcode reports
`sh.pug.sample` unavailable:

```
DEVELOPMENT_TEAM = ABCDE12345
PRODUCT_BUNDLE_IDENTIFIER = com.example.pug-sample
```

## License

[MIT](LICENSE)
