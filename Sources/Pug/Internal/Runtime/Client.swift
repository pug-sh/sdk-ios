/// One configured SDK instance. Calls, and the app's lifecycle callbacks, arrive on any thread: they read the clock and
/// map their arguments there, then queue an op that the worker runs in call order, once the last client's teardown is
/// over and `ClientCore` has restored what earlier launches stored.
final class Client: Sendable {
  /// Bounds the final flush of `destroy()`, which the next client waits for.
  static let teardownTimeoutMillis: Int64 = 10_000

  private struct ConsentView: Sendable {
    let consent: Pug.TrackingConsent
    let isPending: Bool
  }

  // The getters answer on the caller's thread without waiting, each from one read of `view`: the latest choice, else
  // what start-up read, else unknown. whenConsentReady() callbacks wait in `waiters` until start-up has read it.
  private struct ConsentState: Sendable {
    var view: ConsentView?
    var isRead = false
    var waiters: [@MainActor @Sendable () -> Void] = []
    var isUnknownReported = false
  }

  private struct Observation: Sendable {
    var handle: (any Cancellable)?
    var isStopped = false
  }

  /// Finishes once this client, destroyed, no longer touches storage.
  let teardown = Teardown()

  private let configuration: Configuration
  private let logger: SafeLogger
  private let transport: any Transport
  private let scheduler: any Scheduler
  private let clock: any Clock
  private let platform: any Platform
  private let ids: any IdGenerator
  private let random: @Sendable () -> Double
  private let propertyMapper: PropertyMapper
  private let traitsMapper: TraitsMapper
  private let factory: EventFactory
  private let ops: OpQueue<ClientCore>
  private let consent = Locked(ConsentState())
  private let observation = Locked(Observation())

  /// `clock` dates the calls, on the caller's thread; `random` spreads retries as `EventDispatcher` does.
  init(
    configuration: Configuration,
    transport: any Transport,
    scheduler: any Scheduler,
    clock: any Clock,
    platform: any Platform,
    ids: any IdGenerator = UUIDv7Generator(),
    random: @escaping @Sendable () -> Double = { .random(in: 0...1) }
  ) {
    self.configuration = configuration
    logger = configuration.logger
    self.transport = transport
    self.scheduler = scheduler
    self.clock = clock
    self.platform = platform
    self.ids = ids
    self.random = random
    propertyMapper = PropertyMapper(logger: logger)
    traitsMapper = TraitsMapper(logger: logger)
    factory = EventFactory(projectId: configuration.projectId, logger: logger, properties: propertyMapper, ids: ids)
    ops = OpQueue(scheduler: scheduler)
  }

  /// Runs the client once `previous`, the last client's teardown, has finished, and observes the app's lifecycle,
  /// whose callbacks wait for start-up like any call.
  func start(after previous: Teardown?) {
    let startTime = clock.nowMillis
    let begin: @Sendable () -> Void = { [self] in
      scheduler.run { [self] in restore(startTime: startTime) }
    }
    if let previous {
      previous.whenFinished(begin)
    } else {
      begin()
    }
    observeLifecycle()
  }

  /// Runs the calls made so far, then a final flush of at most `teardownTimeoutMillis`, after which `teardown`
  /// finishes. Identity, stored consent and unsent events stay stored.
  func destroy() {
    stopObservingLifecycle()
    ops.close { [teardown] core in
      core.tearDown { teardown.finish() }
    }
  }

  func track(_ kind: String, properties: [String: Any]?, options: Pug.TrackOptions?) {
    let callTime = clock.nowMillis
    guard factory.acceptsKind(kind) else { return }
    // Mapped here, since values the host holds by reference may change once track returns.
    let custom = properties.map { propertyMapper.mapCustom(kind: kind, $0) } ?? [:]
    if let event = WellKnownEvents.byKind[kind] {
      reportMissing(event, custom)
    }
    submitCapture("Pug.track()", kind, custom, at: callTime, options: options)
  }

  /// `values` are `event`'s properties in schema order, nil where the caller left them out.
  func trackTyped(_ event: EventSchema, _ values: [Any?], extras: [String: Any]?, options: Pug.TrackOptions?) {
    let callTime = clock.nowMillis
    let custom = propertyMapper.mapTyped(event, values: values, extras: extras)
    submitCapture("Pug.\(event.label)()", event.kind, custom, at: callTime, options: options)
  }

  func identify(_ externalId: String, traits: [String: Any]?) {
    if externalId.allSatisfy(\.isWhitespace) {
      logger.error("identify() was dropped: externalId is blank")
      return
    }
    // As the distinct id it would fail every batch it is in.
    if externalId.hasUTF8Prefix(Identity.reservedIdPrefix) {
      logger.error("identify() was dropped: externalId may not start with \"\(Identity.reservedIdPrefix)\"")
      return
    }
    let mapped = traits.map(traitsMapper.map) ?? [:]
    enqueue("Pug.identify()") { $0.identify(externalId, traits: mapped) }
  }

  func screen(_ name: String) {
    let callTime = clock.nowMillis
    if name.allSatisfy(\.isWhitespace) {
      logger.warning("A screen with a blank name was dropped")
      return
    }
    enqueue("Pug.screen()") { $0.showScreen(name, screenClass: nil, at: callTime) }
  }

  func reset() {
    let now = clock.nowMillis
    enqueue("Pug.reset()") { $0.reset(at: now) }
  }

  func rotateSession() {
    let now = clock.nowMillis
    enqueue("Pug.rotateSession()") { $0.rotateSession(at: now) }
  }

  func flush() {
    enqueue("Pug.flush()") { $0.flush() }
  }

  func optInTracking() {
    setConsent("optInTracking", .granted)
  }

  func optOutTracking() {
    setConsent("optOutTracking", .denied)
  }

  var trackingConsent: Pug.TrackingConsent? {
    currentConsent()?.consent
  }

  var isTrackingEnabled: Bool {
    currentConsent()?.consent == .granted
  }

  var isConsentPending: Bool {
    currentConsent()?.isPending ?? true
  }

  func whenConsentReady(_ callback: @escaping @MainActor @Sendable () -> Void) {
    let isRead = consent.withLock { state in
      if !state.isRead {
        state.waiters.append(callback)
      }
      return state.isRead
    }
    if isRead {
      platform.runOnMain(callback)
    }
  }

  private func restore(startTime: Int64) {
    let core = ClientCore(
      configuration: configuration,
      transport: transport,
      scheduler: scheduler,
      platform: platform,
      ids: ids,
      random: random,
      propertyMapper: propertyMapper,
      factory: factory
    )
    consentRead(core.trackingConsent, isPending: core.isConsentPending)
    core.start(at: startTime)
    ops.start(with: core)
  }

  /// Releases the whenConsentReady() callbacks once start-up has read consent.
  private func consentRead(_ restored: Pug.TrackingConsent, isPending: Bool) {
    let waiters = consent.withLock { state in
      defer { state.waiters = [] }
      // A choice made since initialize is queued behind this and applied after it, so it stays what the getters
      // report.
      if state.view == nil {
        state.view = ConsentView(consent: restored, isPending: isPending)
      }
      state.isRead = true
      return state.waiters
    }
    for waiter in waiters {
      platform.runOnMain(waiter)
    }
  }

  private func setConsent(_ name: String, _ value: Pug.TrackingConsent) {
    let now = clock.nowMillis
    // Choices made at once on two threads: the getters must report the one queued last, which the worker applies last.
    let isQueued = consent.withLock { state in
      let isQueued = ops.submit { $0.setConsent(value, at: now) }
      if isQueued {
        state.view = ConsentView(consent: value, isPending: false)
      }
      return isQueued
    }
    if !isQueued {
      logger.debug("Pug.\(name)() was ignored: Pug was destroyed")
    }
  }

  private func currentConsent() -> ConsentView? {
    let (view, isFirstReport) = consent.withLock { state -> (ConsentView?, Bool) in
      if let view = state.view {
        return (view, false)
      }
      defer { state.isUnknownReported = true }
      return (nil, !state.isUnknownReported)
    }
    if view == nil {
      let message =
        "Tracking consent was asked for before Pug read it from storage; it is reported as unknown. Ask from "
        + "Pug.whenConsentReady() instead"
      if isFirstReport {
        logger.warning(message)
      } else {
        logger.debug(message)
      }
    }
    return view
  }

  private func reportMissing(_ event: EventSchema, _ properties: [String: PropertyValue]) {
    guard logger.isDebugEnabled else { return }
    let missing = event.fields.filter { $0.required && properties[$0.name] == nil }.map { "\"\($0.name)\"" }
    if !missing.isEmpty {
      logger.debug("Event \"\(event.kind)\" is missing its required \(missing.joined(separator: ", "))")
    }
  }

  private func submitCapture(
    _ caller: String,
    _ kind: String,
    _ custom: [String: PropertyValue],
    at callTime: Int64,
    options: Pug.TrackOptions?
  ) {
    let occurTime = factory.occurTime(kind: kind, timestamp: options?.timestamp, callTimeMillis: callTime)
    let immediate = options?.immediate == true
    enqueue(caller) { $0.capture(kind, custom, at: callTime, occurTime: occurTime, immediate: immediate) }
  }

  /// Queues `op` for the worker. Once the client is destroyed, logs `label` as ignored and returns false.
  @discardableResult
  private func enqueue(_ label: String, _ op: @escaping @Sendable (ClientCore) -> Void) -> Bool {
    let isQueued = ops.submit(op)
    if !isQueued {
      logger.debug("\(label) was ignored: Pug was destroyed")
    }
    return isQueued
  }

  // A destroy() on another thread can come before this, and must still stop what this starts.
  private func observeLifecycle() {
    let handle = platform.observeLifecycle(self, logger: logger)
    if handle == nil {
      logger.debug("App open, close and screen events are not tracked: there is no app lifecycle to observe")
    }
    let isStopped = observation.withLock { state in
      if !state.isStopped {
        state.handle = handle
      }
      return state.isStopped
    }
    if isStopped {
      handle?.cancel()
    }
  }

  private func stopObservingLifecycle() {
    let handle = observation.withLock { state in
      defer { state.handle = nil }
      state.isStopped = true
      return state.handle
    }
    handle?.cancel()
  }
}

/// Callbacks from the main thread, queued like calls so that they run in order with them.
extension Client: LifecycleObserver {
  func appDidEnterForeground() {
    let now = clock.nowMillis
    enqueue("Tracking the app moving to the foreground") { $0.enterForeground(at: now) }
  }

  func appDidEnterBackground(then settled: @escaping @Sendable () -> Void) {
    let now = clock.nowMillis
    if !enqueue("Tracking the app moving to the background", { $0.enterBackground(at: now, then: settled) }) {
      settled()
    }
  }

  func screenDidAppear(name: String, screenClass: String) {
    guard configuration.autoScreenViews else { return }
    let now = clock.nowMillis
    enqueue("Tracking a screen view") { $0.showScreen(name, screenClass: screenClass, at: now) }
  }
}
