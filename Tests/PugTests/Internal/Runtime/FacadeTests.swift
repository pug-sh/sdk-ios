import Foundation
import Testing

@testable import Pug

struct FacadeTests {
  private static let project = "proj_1"

  private let scheduler: TestScheduler
  private let transport: FakeTransport
  private let logger = RecordingLogger()
  private let fallbackLogger = RecordingLogger()
  private let storage = Pug.MemoryStorage()
  private let platform = FakePlatform()
  private let facade: Facade

  init() {
    let scheduler = TestScheduler()
    let transport = FakeTransport { scheduler.currentTime }
    let ids = SequentialIds()
    let platform = platform
    self.scheduler = scheduler
    self.transport = transport
    facade = Facade(fallbackLogger: fallbackLogger.safe(debug: false)) { configuration in
      Client(
        configuration: configuration,
        transport: transport,
        scheduler: scheduler,
        clock: scheduler,
        platform: platform,
        ids: ids,
        random: { 0.5 }
      )
    }
  }

  @Test("initialize refuses invalid arguments and leaves Pug stopped")
  func refused() {
    #expect(throws: Pug.ConfigurationError("Pug.initialize() needs a project id")) {
      try facade.initialize(projectId: " ", options: options())
    }
    #expect(throws: Pug.ConfigurationError.self) {
      try facade.initialize(projectId: Self.project, options: options(apiKey: "prv_key"))
    }

    #expect(facade.trackingConsent == nil)
  }

  @Test("calls before initialize are ignored with a warning")
  func callsBeforeInitialize() {
    let track = Pug.TrackNamespace(facade: facade)

    facade.track("a", properties: nil, options: nil)
    track.addToCart(productId: "p1")
    facade.identify("user-1", traits: nil)
    facade.screen("Home")
    facade.reset()
    facade.rotateSession()
    facade.flush()
    facade.optInTracking()
    facade.optOutTracking()
    facade.whenConsentReady {}
    facade.destroy()

    #expect(facade.trackingConsent == nil)
    #expect(!facade.isTrackingEnabled)
    #expect(facade.isConsentPending)
    let calls = [
      "track", "track.addToCart", "identify", "screen", "reset", "rotateSession", "flush", "optInTracking",
      "optOutTracking", "whenConsentReady", "destroy",
    ]
    #expect(
      fallbackLogger.warnings
        == calls.map { "Pug.\($0)() was called before Pug.initialize(); it was ignored" } + [
          "Pug.trackingConsent was read before Pug.initialize(); returning nil",
          "Pug.isTrackingEnabled was read before Pug.initialize(); returning false",
          "Pug.isConsentPending was read before Pug.initialize(); returning true",
        ]
    )
  }

  @Test("a second initialize is ignored, its options unread")
  func secondInitialize() throws {
    let otherLogger = RecordingLogger()
    try facade.initialize(projectId: Self.project, options: options())
    var other = Pug.Options(apiKey: "pub_other")
    other.logger = otherLogger
    other.batchMaxSize = 0

    try facade.initialize(projectId: "other", options: other)
    facade.track("a", properties: nil, options: Pug.TrackOptions(immediate: true))
    scheduler.runCurrent()

    #expect(otherLogger.warnings == ["Pug.initialize() was called again; the first configuration stays"])
    #expect(try transport.batches.single().single().autoProperties["$projectId"] == .string(Self.project))
  }

  @Test("initialize logs the options it replaced")
  func replacedOptions() throws {
    try facade.initialize(projectId: Self.project, options: options { $0.batchMaxQueueSize = 0 })

    #expect(logger.warnings == ["batchMaxQueueSize 0 must be at least 1; using 1000"])
  }

  @Test("typed events go through the running client")
  func typed() throws {
    try facade.initialize(projectId: Self.project, options: options { $0.batchMaxSize = 1 })

    Pug.TrackNamespace(facade: facade).addToCart(productId: "p1", price: 10)
    scheduler.runCurrent()

    let event = try transport.batches.single().single()
    #expect(event.kind == "add_to_cart")
    #expect(event.customProperties == ["productId": .string("p1"), "price": .double(10)])
  }

  @Test("the consent getters answer through the running client")
  func consentGetters() throws {
    try facade.initialize(projectId: Self.project, options: options { $0.defaultTrackingConsent = .denied })
    scheduler.runCurrent()

    #expect(facade.trackingConsent == .denied)
    #expect(!facade.isTrackingEnabled)
    #expect(facade.isConsentPending)
    facade.optInTracking()
    #expect(facade.trackingConsent == .granted)
    #expect(!facade.isConsentPending)
  }

  @Test("a new client waits for the last one's teardown before reading storage")
  func waitsForTeardown() throws {
    let options = options { $0.batchMaxSize = 2 }
    try facade.initialize(projectId: Self.project, options: options)
    transport.hold()
    facade.track("a", properties: nil, options: nil)
    facade.track("b", properties: nil, options: nil)
    scheduler.runCurrent()
    facade.track("c", properties: nil, options: nil)

    facade.destroy()
    try facade.initialize(projectId: Self.project, options: options)
    facade.track("d", properties: nil, options: nil)
    scheduler.runCurrent()
    #expect(transport.batches.count == 1)
    transport.releaseAll()
    scheduler.runCurrent()
    facade.flush()
    scheduler.runCurrent()

    // Started early, the new client would have read a, b and c from storage and sent them again.
    #expect(transport.kinds == [["a", "b"], ["c"], ["d"]])
  }

  @Test("whenConsentReady waits for the client that is running when its callback is due")
  @MainActor
  func whenConsentReadyFollowsTheRunningClient() throws {
    let options = options { $0.defaultTrackingConsent = .denied }
    try facade.initialize(projectId: Self.project, options: options)
    facade.optInTracking()
    facade.destroy()
    scheduler.advanceUntilIdle()

    try facade.initialize(projectId: Self.project, options: options)
    let seen = Locked<[ConsentAnswer]>([])
    facade.whenConsentReady { [facade] in
      seen.withLock { $0.append(ConsentAnswer(consent: facade.trackingConsent, isPending: facade.isConsentPending)) }
    }
    transport.hold()
    facade.track("a", properties: nil, options: nil)
    facade.destroy()
    try facade.initialize(projectId: Self.project, options: options)
    // The second client has read consent and is in its final flush, which the third one waits for.
    scheduler.runCurrent()
    platform.runMainThread()
    #expect(seen.withLock { $0 }.isEmpty)

    transport.releaseAll()
    scheduler.runCurrent()
    platform.runMainThread()

    #expect(seen.withLock { $0 } == [ConsentAnswer(consent: .granted, isPending: false)])
    #expect(logger.warnings.isEmpty)
  }

  @Test("destroy keeps the identity for the next initialize")
  func destroyKeepsIdentity() throws {
    try facade.initialize(projectId: Self.project, options: options())
    facade.identify("user-1", traits: nil)
    scheduler.runCurrent()

    facade.destroy()
    try facade.initialize(projectId: Self.project, options: options())
    facade.track("a", properties: nil, options: Pug.TrackOptions(immediate: true))
    scheduler.runCurrent()

    #expect(try transport.batches.single().single().distinctId == "user-1")
  }

  @Test("calls after destroy are ignored with a warning")
  func callsAfterDestroy() throws {
    try facade.initialize(projectId: Self.project, options: options())
    facade.destroy()

    facade.track("a", properties: nil, options: nil)
    scheduler.advanceUntilIdle()

    #expect(transport.batches.isEmpty)
    #expect(fallbackLogger.warnings == ["Pug.track() was called before Pug.initialize(); it was ignored"])
  }

  private func options(apiKey: String = "pub_key", _ configure: (inout Pug.Options) -> Void = { _ in }) -> Pug.Options {
    var options = Pug.Options(apiKey: apiKey)
    options.logger = logger
    options.storage = storage
    configure(&options)
    return options
  }
}
