/// Pug analytics: events, identity, sessions and tracking consent, delivered in batches. Call
/// `initialize(projectId:options:)` once at launch. Every other call returns at once, works from any thread and never
/// throws: failures, and calls made before `initialize`, are logged.
public enum Pug {
  private static let facade = Facade.shared

  /// The well-known events as typed calls: `Pug.track.addToCart(productId: "p1", price: 9.99)`.
  public static let track = TrackNamespace(facade: facade)

  /// Starts Pug for `projectId`, with no disk or network work on the calling thread. A second call is ignored with a
  /// warning until `destroy()`.
  ///
  /// - Throws: `ConfigurationError` for a blank project id, an API key that is not a public key (`pub_…`) or an
  ///   endpoint that is not an http(s) URL without a query or fragment.
  public static func initialize(projectId: String, options: Options) throws(ConfigurationError) {
    try facade.initialize(projectId: projectId, options: options)
  }

  /// Tracks an event. `kind` may contain letters, digits, `_`, `.` and `-`. `properties` are read during the call, and
  /// keys starting with `$` are reserved and dropped.
  public static func track(_ kind: String, properties: [String: Any]? = nil, options: TrackOptions? = nil) {
    facade.track(kind, properties: properties, options: options)
  }

  /// Identifies the user by your own id, with optional traits. The first call links the events tracked anonymously so
  /// far to that user. Never retried; a failure is logged.
  public static func identify(_ externalId: String, traits: [String: Any]? = nil) {
    facade.identify(externalId, traits: traits)
  }

  /// Tracks a `screen_view` of the screen `name` unless it is the current one, and reports it as `$url` on the events
  /// that follow. For screens that are not view controllers, such as SwiftUI views.
  public static func screen(_ name: String) {
    facade.screen(name)
  }

  /// For a logout: a new anonymous id and session, and no external id. Queued events are still sent.
  public static func reset() {
    facade.reset()
  }

  /// Ends the current session; the next event starts a new one.
  public static func rotateSession() {
    facade.rotateSession()
  }

  /// Sends queued events now, and writes Pug's state to storage.
  public static func flush() {
    facade.flush()
  }

  /// Stops Pug after a final flush of at most ten seconds. Identity, stored consent and undelivered events are kept for
  /// the next `initialize`, which waits for this to finish.
  public static func destroy() {
    facade.destroy()
  }

  /// Grants tracking consent, and tracks what consent held back: this launch's install or update and, with the app on
  /// screen, `app_open` and the current screen.
  public static func optInTracking() {
    facade.optInTracking()
  }

  /// Denies tracking consent: queued events are dropped unsent, the stored identity is removed, and events and
  /// `identify` are dropped until `optInTracking()`.
  public static func optOutTracking() {
    facade.optOutTracking()
  }

  /// The consent in effect, or nil while it is not known: before `initialize`, and right after it until Pug has read
  /// what an earlier launch stored, unless the user has chosen since. Never waits; see `whenConsentReady(_:)`.
  public static var trackingConsent: TrackingConsent? {
    facade.trackingConsent
  }

  /// Whether consent is granted, `dryRun` or not. False while consent is not known.
  public static var isTrackingEnabled: Bool {
    facade.isTrackingEnabled
  }

  /// Whether the user has yet to choose, the cue for a consent prompt. True while consent is not known, so ask from
  /// `whenConsentReady(_:)`.
  public static var isConsentPending: Bool {
    facade.isConsentPending
  }

  /// Runs `callback` once on the main thread as soon as the consent getters answer for this user, on the main thread's
  /// next turn if they already do. Ignored before `initialize`.
  ///
  /// ```swift
  /// Pug.whenConsentReady { if Pug.isConsentPending { showConsentPrompt() } }
  /// ```
  public static func whenConsentReady(_ callback: @escaping @MainActor @Sendable () -> Void) {
    facade.whenConsentReady(callback)
  }
}
