/// A client's state, confined to the worker: restored once the last client's teardown is over, then changed only by the
/// client's ops and the answers to its requests. Besides identity, consent and delivery, it holds the foreground state
/// (`app_open`, `app_close`) and the current screen (`$url`, `$referrer`).
final class ClientCore: @unchecked Sendable {
  private let configuration: Configuration
  private let logger: SafeLogger
  private let transport: any Transport
  private let scheduler: any Scheduler
  private let propertyMapper: PropertyMapper
  private let factory: EventFactory
  private let fileStorage: FileStorage?
  private let autoProperties: any AutoProperties
  private let installs: InstallTracker
  private let identity: Identity
  private let dispatcher: EventDispatcher
  private let consent: TrackingConsentController
  private var isDisposed = false
  private var identifyCalls = 0
  private var linkedIdentifyCall = 0
  private var identifiesInFlight = 0
  private var identifiesSettled: [() -> Void] = []
  // The app as the worker sees it: whether it is on screen, and whether this visit's app_open was captured, which
  // app_close must follow.
  private var isVisible = false
  private var isOpen = false
  // What $url and $referrer report.
  private var screen: String?
  private var screenClass: String?
  private var previousScreen: String?
  // Whether the view controller that set the screen last has disappeared, and whether another screen became current
  // while it was away. Back with none in between, it is the same screen, and a name screen() gave it stays current.
  private var isAutoScreenHidden = false
  private var isAutoScreenReplaced = false

  /// The storage `configuration` asks for: the host's, else files in the platform's directory, else memory.
  static func storage(
    configuration: Configuration,
    platform: any Platform,
    scheduler: any Scheduler
  ) -> (primary: any Pug.Storage, files: FileStorage?) {
    if let storage = configuration.storage {
      return (storage, nil)
    }
    guard let directory = platform.storageDirectory() else {
      configuration.logger.warning(
        "No storage directory is available; state is kept in memory until the app restarts")
      return (Pug.MemoryStorage(), nil)
    }
    // iOS stops an app extension without notice, so it writes each change at once.
    let files = FileStorage(
      directory: directory,
      logger: configuration.logger,
      scheduler: scheduler,
      syncDelayMillis: platform.isAppExtension ? 0 : FileStorage.syncDelayMillis
    )
    return (files, files)
  }

  /// `primary` and `fileStorage` come from `storage(configuration:platform:scheduler:)`.
  init(
    configuration: Configuration,
    transport: any Transport,
    scheduler: any Scheduler,
    platform: any Platform,
    primary: any Pug.Storage,
    fileStorage: FileStorage?,
    ids: any IdGenerator,
    random: @escaping @Sendable () -> Double,
    propertyMapper: PropertyMapper,
    factory: EventFactory
  ) {
    assert(scheduler.isOnWorker)
    let logger = configuration.logger
    let keys = StorageKeys(projectId: configuration.projectId)
    let storage = SafeStorage(primary, logger: logger)
    // Read first, while a failed read can only mean a stored choice that cannot be read: the controller denies it,
    // as it may be an opt-out, and install detection is skipped.
    consent = TrackingConsentController(
      storage: storage,
      key: keys.consent,
      logger: logger,
      defaultConsent: configuration.defaultTrackingConsent,
      persists: configuration.persistTrackingConsent
    )
    let autoProperties = platform.autoProperties(logger: logger)
    let installs = InstallTracker(storage: storage, keys: keys, logger: logger)
    // Before anything this launch writes, so the probe for earlier launches sees only theirs. An extension has a
    // container of its own, where each would look like a new install.
    if configuration.autoInstallEvents, platform.isAppExtension {
      logger.debug("app_install and app_update are not tracked in an app extension")
    } else if configuration.autoInstallEvents {
      installs.check(appVersion: autoProperties.appVersion, installSource: platform.installSource)
    }
    let identity = Identity(
      storage: storage,
      keys: keys,
      logger: logger,
      ids: ids,
      idleTimeoutMillis: configuration.sessionIdleTimeoutMillis,
      maxDurationMillis: configuration.sessionMaxDurationMillis
    )
    let queue = EventQueue(
      storage: storage, key: keys.queue, logger: logger, maxQueueSize: configuration.batchMaxQueueSize)
    let dispatcher = EventDispatcher(
      queue: queue,
      transport: transport,
      logger: logger,
      scheduler: scheduler,
      maxSize: configuration.batchMaxSize,
      maxWaitMillis: configuration.batchMaxWaitMillis,
      random: random
    )
    self.configuration = configuration
    self.logger = logger
    self.transport = transport
    self.scheduler = scheduler
    self.propertyMapper = propertyMapper
    self.factory = factory
    self.fileStorage = fileStorage
    self.autoProperties = autoProperties
    self.installs = installs
    self.identity = identity
    self.dispatcher = dispatcher
  }

  var trackingConsent: Pug.TrackingConsent {
    consent.consent
  }

  var isConsentPending: Bool {
    consent.isPending
  }

  private var purge: Purge {
    Purge(identity: identity, dispatcher: dispatcher, logger: logger)
  }

  /// Brings the device in line with consent, tracks this launch's install or update, dated `startTime`, and starts
  /// delivering what earlier launches left.
  func start(at startTime: Int64) {
    assert(scheduler.isOnWorker)
    consent.enforceAtInit(purging: purge)
    // Dated at initialize: the launch's app_open was dated on the main thread, and may precede this.
    installs.emit { kind, properties in captureInstall(kind, properties, at: startTime) }
    dispatcher.start()
    if configuration.dryRun {
      logger.warning("dryRun is on: events and identify() are logged, never sent")
    }
    logger.debug("Pug started for project \"\(configuration.projectId)\"")
  }

  /// Returns whether consent let the event through, which the lifecycle and install state follow.
  @discardableResult
  func capture(
    _ kind: String,
    _ custom: [String: PropertyValue],
    at callTime: Int64,
    occurTime: Int64? = nil,
    immediate: Bool = false
  ) -> Bool {
    assert(scheduler.isOnWorker)
    guard consent.isGranted else {
      logger.debug("Event \"\(kind)\" was dropped: tracking consent is denied")
      return false
    }
    let sessionId = identity.sessionId(at: callTime)
    guard
      let event = factory.create(
        kind: kind,
        customProperties: custom,
        autoProperties: currentAutoProperties(),
        distinctId: identity.distinctId,
        sessionId: sessionId,
        occurTimeMillis: occurTime ?? callTime
      )
    else { return false }
    if configuration.dryRun {
      logger.debug("dryRun: event \"\(kind)\" was not sent")
      return true
    }
    if immediate {
      dispatcher.sendNow(event)
    } else {
      dispatcher.enqueue(event)
    }
    logger.debug("Tracked \"\(kind)\"")
    return true
  }

  func identify(_ externalId: String, traits: [String: JSONValue]) {
    assert(scheduler.isOnWorker)
    guard consent.isGranted else {
      logger.debug("identify() was dropped: tracking consent is denied")
      return
    }
    guard !configuration.dryRun else {
      logger.debug("dryRun: identify() was not sent")
      return
    }
    let anonymousId = identity.anonymousId
    // Only the first identify links the anonymous history to the user.
    let request = IdentifyRequest(
      externalId: externalId,
      traits: traits,
      anonymousId: identity.externalId == nil ? anonymousId : nil
    )
    identifyCalls &+= 1
    let call = identifyCalls
    identifiesInFlight += 1
    transport.identify(request) { [self] result in
      scheduler.run { [self] in identified(externalId, anonymousId: anonymousId, call: call, result) }
    }
  }

  func reset(at now: Int64) {
    assert(scheduler.isOnWorker)
    if consent.isGranted {
      identity.reset(at: now)
      // Queued events keep the outgoing user's distinct id: send them rather than hold them.
      dispatcher.flush()
    } else {
      identity.clear()
    }
    logger.debug("reset() cleared the identity; the next event starts a new one")
  }

  func rotateSession(at now: Int64) {
    assert(scheduler.isOnWorker)
    guard consent.isGranted else {
      logger.debug("rotateSession() was ignored: tracking consent is denied")
      return
    }
    identity.rotateSession(at: now)
  }

  func showScreen(_ name: String, screenClass: String?, at callTime: Int64) {
    assert(scheduler.isOnWorker)
    let shown = name.truncatedUTF8(maxBytes: Limits.maxStringBytes)
    if shown.utf8.count != name.utf8.count {
      logger.warning("A screen name was truncated to \(Limits.maxStringBytes) bytes")
    }
    guard !shown.isUTF8Equal(screen) else {
      logger.debug("A screen view was not tracked: the screen is the current one")
      return
    }
    if isAutoScreenHidden {
      isAutoScreenReplaced = true
    }
    previousScreen = screen
    screen = shown
    self.screenClass = screenClass
    captureScreenView(shown, screenClass: screenClass, at: callTime)
  }

  func showAutoScreen(_ name: String, screenClass: String?, isReturning: Bool, at callTime: Int64) {
    assert(scheduler.isOnWorker)
    defer {
      isAutoScreenHidden = false
      isAutoScreenReplaced = false
    }
    if isReturning, !isAutoScreenReplaced {
      logger.debug("A screen view was not tracked: its view controller is back on the current screen")
      return
    }
    showScreen(name, screenClass: screenClass, at: callTime)
  }

  func hideAutoScreen() {
    assert(scheduler.isOnWorker)
    isAutoScreenHidden = true
  }

  func flush() {
    assert(scheduler.isOnWorker)
    drainAndPersist()
  }

  func setConsent(_ value: Pug.TrackingConsent, at now: Int64) {
    assert(scheduler.isOnWorker)
    let wasGranted = consent.isGranted
    consent.set(value, purging: purge)
    // An opt-out and its purge must survive a process killed before the write-behind.
    fileStorage?.sync()
    logger.debug("Tracking consent is now \(value)")
    if value == .denied {
      // The identity that saw this visit's app_open is gone; the next visit opens afresh.
      isOpen = false
    } else if !wasGranted {
      // What a launch would have tracked, had consent allowed it then.
      installs.emit { kind, properties in captureInstall(kind, properties, at: now) }
      if isVisible {
        open(at: now)
        if let screen {
          captureScreenView(screen, screenClass: screenClass, at: now)
        }
      }
    }
  }

  func enterForeground(at now: Int64) {
    assert(scheduler.isOnWorker)
    isVisible = true
    open(at: now)
  }

  func enterBackground(at now: Int64, then settled: @escaping @Sendable () -> Void) {
    assert(scheduler.isOnWorker)
    isVisible = false
    if configuration.autoOpenCloseEvents, isOpen, capture(Pug.Events.appClose, [:], at: now, immediate: true) {
      isOpen = false
    }
    // The app may be suspended or killed from here on: whatever is queued gets its send now.
    drainAndPersist(then: settled)
  }

  /// Sends what is queued and waits for the network, for at most `Client.teardownTimeoutMillis`, then lets go of
  /// storage and runs `finished`. What stays undelivered stays stored.
  func tearDown(then finished: @escaping @Sendable () -> Void) {
    assert(scheduler.isOnWorker)
    dispatcher.close()
    let deadline = scheduler.runAfter(milliseconds: Client.teardownTimeoutMillis) { [self] in
      logger.warning("Pug.destroy() stopped waiting for the network after \(Client.teardownTimeoutMillis) ms")
      dispose(then: finished)
    }
    dispatcher.drain { [self] in
      whenIdentifiesSettle { [self] in
        deadline.cancel()
        dispose(then: finished)
      }
    }
  }

  // Runs once, whichever of the network and the deadline comes first: disposing completes the drain as well.
  private func dispose(then finished: @Sendable () -> Void) {
    guard !isDisposed else { return }
    isDisposed = true
    dispatcher.dispose()
    // Answers from here on are ignored, so an identify the server applied later would go unrecorded.
    transport.cancelAll()
    fileStorage?.sync()
    let undelivered = dispatcher.undelivered
    if undelivered > 0 {
      logger.debug("Keeping \(eventCount(undelivered)) for the next Pug.initialize()")
    }
    logger.debug("Pug was destroyed")
    finished()
  }

  private func identified(
    _ externalId: String,
    anonymousId: String,
    call: Int,
    _ result: Result<Void, TransportError>
  ) {
    switch result {
    case .failure(let failure):
      logger.error("identify() failed (\(failure))", error: failure.underlying)
    case .success where isDisposed:
      break
    // A reset() or an opt-out during the request: linking now would bring back the identity the host just cleared.
    case .success where !identity.isCurrentAnonymousId(anonymousId):
      logger.debug("identify() finished after the identity was reset; it was not applied")
    case .success where call < linkedIdentifyCall:
      logger.debug("identify() finished after a later identify(); the later one stands")
    case .success:
      identity.link(externalId)
      linkedIdentifyCall = call
      logger.debug("identify() succeeded")
    }
    identifiesInFlight -= 1
    if identifiesInFlight == 0 {
      let settled = identifiesSettled
      identifiesSettled.removeAll()
      for work in settled {
        work()
      }
    }
  }

  private func whenIdentifiesSettle(_ work: @escaping () -> Void) {
    if identifiesInFlight == 0 {
      work()
    } else {
      identifiesSettled.append(work)
    }
  }

  private func currentAutoProperties() -> [String: Any] {
    var properties = autoProperties.current()
    if let screen {
      properties["$url"] = screen
    }
    if let previousScreen {
      properties["$referrer"] = previousScreen
    }
    return properties
  }

  private func captureInstall(_ kind: String, _ properties: [String: String], at time: Int64) -> Bool {
    capture(kind, propertyMapper.mapCustom(kind: kind, properties), at: time)
  }

  private func captureScreenView(_ name: String, screenClass: String?, at callTime: Int64) {
    var properties = ["screenName": name]
    properties["screenClass"] = screenClass
    capture(Pug.Events.screenView, propertyMapper.mapCustom(kind: Pug.Events.screenView, properties), at: callTime)
  }

  private func open(at now: Int64) {
    guard configuration.autoOpenCloseEvents, !isOpen else { return }
    isOpen = capture(Pug.Events.appOpen, [:], at: now)
  }

  /// Sends every queued event, backoff or not, and writes storage now and again once the sends and identify calls
  /// settle, when `settled` runs.
  private func drainAndPersist(then settled: (@Sendable () -> Void)? = nil) {
    dispatcher.drain { [self] in
      whenIdentifiesSettle { [self] in
        if !isDisposed {
          fileStorage?.sync()
        }
        settled?()
      }
    }
    fileStorage?.sync()
  }
}

/// What opting out purges.
private struct Purge: ConsentPurge {
  let identity: Identity
  let dispatcher: EventDispatcher
  let logger: SafeLogger

  var isIdentified: Bool {
    identity.externalId != nil
  }

  func dropQueue() {
    let dropped = dispatcher.clear()
    if dropped > 0 {
      logger.debug("Dropped \(eventCount(dropped)) unsent: tracking consent is denied")
    }
  }

  func forgetIdentity() {
    identity.clear()
  }
}
