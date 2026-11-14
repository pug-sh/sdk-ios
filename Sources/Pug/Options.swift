import Foundation

extension Pug {
  /// How `Pug.initialize(projectId:options:)` sets Pug up. Only the API key is required. A number out of range is
  /// logged and replaced by its default; a `batchMaxSize` above 1000 is capped instead.
  public struct Options: Sendable {
    // URL(string:) is optional even for a literal: the fallback never runs.
    private static let defaultEndpoint = URL(string: "https://api.pugs.dev") ?? URL(fileURLWithPath: "/")

    /// The project's public key, `pub_…`.
    public var apiKey: String

    /// The base URL of the Pug API.
    public var endpoint = defaultEndpoint

    /// Logs debug messages: each event tracked, sent or dropped, and why. Warnings and errors are always logged.
    public var debug = false

    /// Builds and logs events without sending anything, `identify` included.
    public var dryRun = false

    /// Events go out in requests of up to this many, at most 1000: once that many are queued, or `batchMaxWait` after
    /// the first of them.
    public var batchMaxSize = 10

    /// How long the first queued event waits for a full batch, in seconds.
    public var batchMaxWait: TimeInterval = 5

    /// Beyond this many undelivered events, the oldest is dropped.
    public var batchMaxQueueSize = 1_000

    /// A session ends after this many seconds without events.
    public var sessionIdleTimeout: TimeInterval = 30 * 60

    /// A session ends this many seconds after it began.
    public var sessionMaxDuration: TimeInterval = 24 * 60 * 60

    /// The consent in effect until the user chooses.
    public var defaultTrackingConsent = TrackingConsent.granted

    /// Stores the user's choice for the next launch. Turned off, a choice lasts until `Pug.destroy()` or the process
    /// ends: for an app that keeps it itself and calls `Pug.optInTracking()` or `Pug.optOutTracking()` at each launch.
    public var persistTrackingConsent = true

    /// Tracks `app_open` and `app_close` as the app comes to the foreground and leaves it.
    public var autoOpenCloseEvents = true

    /// Tracks a `screen_view` each time one of the app's own view controllers appears on a different screen. SwiftUI
    /// screens are named with `pugScreen(_:)`, tracked either way.
    public var autoScreenViews = true

    /// Tracks `app_install` and `app_update` on the first launch of each app version.
    public var autoInstallEvents = true

    /// Receives Pug's messages instead of the system log.
    public var logger: (any Logger)?

    /// Keeps Pug's state instead of files on the device. `MemoryStorage` keeps nothing.
    public var storage: (any Storage)?

    public init(apiKey: String) {
      self.apiKey = apiKey
    }
  }
}
