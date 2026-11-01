/// The state behind `Pug`: the running client, and the last client's teardown, which the next one waits for before it
/// touches storage. Callable from any thread; only `initialize` throws, and only for invalid arguments.
final class Facade: TypedTracking {
  private struct State: Sendable {
    var client: Client?
    var teardown: Teardown?
  }

  /// What `Pug` calls. Its clients share one worker, so two never touch storage at once.
  static let shared: Facade = {
    let scheduler = DispatchScheduler()
    let platform = FoundationPlatform()
    return Facade(fallbackLogger: SafeLogger(SystemLogger(), isDebugEnabled: false)) { configuration in
      Client(
        configuration: configuration,
        transport: HTTPTransport(
          endpoint: configuration.endpoint,
          apiKey: configuration.apiKey,
          logger: configuration.logger
        ),
        scheduler: scheduler,
        clock: scheduler,
        platform: platform
      )
    }
  }()

  private let fallbackLogger: SafeLogger
  private let makeClient: @Sendable (Configuration) -> Client
  private let state = Locked(State())

  /// `fallbackLogger` reports the calls made while no client is running.
  init(fallbackLogger: SafeLogger, makeClient: @escaping @Sendable (Configuration) -> Client) {
    self.fallbackLogger = fallbackLogger
    self.makeClient = makeClient
  }

  func initialize(projectId: String, options: Pug.Options) throws(Pug.ConfigurationError) {
    let configuration = try Configuration(projectId: projectId, options: options)
    let client = makeClient(configuration)
    let (isRunning, previous) = state.withLock { state -> (Bool, Teardown?) in
      guard state.client == nil else { return (false, nil) }
      state.client = client
      return (true, state.teardown)
    }
    guard isRunning else {
      configuration.logger.warning("Pug.initialize() was called again; the first configuration stays")
      return
    }
    for warning in configuration.warnings {
      configuration.logger.warning(warning)
    }
    client.start(after: previous)
  }

  func track(_ kind: String, properties: [String: Any]?, options: Pug.TrackOptions?) {
    call("track") { $0.track(kind, properties: properties, options: options) }
  }

  func trackTyped(_ event: EventSchema, _ values: [Any?], extras: [String: Any]?, options: Pug.TrackOptions?) {
    call(event.label) { $0.trackTyped(event, values, extras: extras, options: options) }
  }

  func identify(_ externalId: String, traits: [String: Any]?) {
    call("identify") { $0.identify(externalId, traits: traits) }
  }

  func screen(_ name: String) {
    call("screen") { $0.screen(name) }
  }

  func reset() {
    call("reset") { $0.reset() }
  }

  func rotateSession() {
    call("rotateSession") { $0.rotateSession() }
  }

  func flush() {
    call("flush") { $0.flush() }
  }

  func optInTracking() {
    call("optInTracking") { $0.optInTracking() }
  }

  func optOutTracking() {
    call("optOutTracking") { $0.optOutTracking() }
  }

  var trackingConsent: Pug.TrackingConsent? {
    read("trackingConsent", fallback: nil) { $0.trackingConsent }
  }

  var isTrackingEnabled: Bool {
    read("isTrackingEnabled", fallback: false) { $0.isTrackingEnabled }
  }

  var isConsentPending: Bool {
    read("isConsentPending", fallback: true) { $0.isConsentPending }
  }

  func whenConsentReady(_ callback: @escaping @MainActor @Sendable () -> Void) {
    call("whenConsentReady") { owner in
      // Destroyed before it ran, its client would release it while the getters already ask the next client, which
      // may not have read consent yet: that one releases it instead.
      owner.whenConsentReady { [self] in
        if state.withLock({ $0.client === owner }) {
          callback()
        } else {
          whenConsentReady(callback)
        }
      }
    }
  }

  func destroy() {
    let client = state.withLock { state -> Client? in
      guard let client = state.client else { return nil }
      state.client = nil
      state.teardown = client.teardown
      return client
    }
    guard let client else {
      fallbackLogger.warning("Pug.destroy() was called before Pug.initialize(); it was ignored")
      return
    }
    client.destroy()
  }

  private func call(_ name: String, _ body: (Client) -> Void) {
    guard let client = state.withLock({ $0.client }) else {
      fallbackLogger.warning("Pug.\(name)() was called before Pug.initialize(); it was ignored")
      return
    }
    body(client)
  }

  private func read<Value>(_ name: String, fallback: Value, _ body: (Client) -> Value) -> Value {
    guard let client = state.withLock({ $0.client }) else {
      fallbackLogger.warning(
        "Pug.\(name) was read before Pug.initialize(); returning \(String(describing: fallback))")
      return fallback
    }
    return body(client)
  }
}
