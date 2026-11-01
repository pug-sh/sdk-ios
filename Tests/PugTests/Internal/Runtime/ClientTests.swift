import Foundation
import Testing

@testable import Pug

struct ClientTests {
  private static let project = "proj_1"
  private static let start: Int64 = 1_760_000_000_000

  /// Reads as empty, and fails every write.
  private final class UnwritableStorage: Pug.Storage {
    private struct ReadOnly: Error {}

    func string(forKey key: String) -> String? {
      nil
    }

    func setString(_ value: String, forKey key: String) throws {
      throw ReadOnly()
    }

    func removeValue(forKey key: String) throws {
      throw ReadOnly()
    }
  }

  /// Records like its base, and runs `onWarning` after each warning.
  private struct HookLogger: Pug.Logger {
    let base: RecordingLogger
    let onWarning: @Sendable (String) -> Void

    func debug(_ message: String) {
      base.debug(message)
    }

    func warning(_ message: String, error: (any Error)?) {
      base.warning(message, error: error)
      onWarning(message)
    }

    func error(_ message: String, error: (any Error)?) {
      base.error(message, error: error)
    }
  }

  private let scheduler: TestScheduler
  private let transport: FakeTransport
  private let logger = RecordingLogger()
  private let storage = Pug.MemoryStorage()
  private let keys = StorageKeys(projectId: ClientTests.project)
  private let ids = SequentialIds()
  private let platform = FakePlatform()

  init() {
    let scheduler = TestScheduler(startMillis: Self.start)
    self.scheduler = scheduler
    transport = FakeTransport { scheduler.currentTime }
  }

  @Test("an event carries the session, the anonymous id and the time of the call")
  func eventIdentity() throws {
    let client = try makeClient { $0.batchMaxSize = 1 }

    scheduler.advanceTime(by: 1_000)
    client.track("add_to_cart", properties: ["productId": "p1", "quantity": 2], options: nil)
    scheduler.runCurrent()

    let event = try transport.batches.single().single()
    #expect(event.kind == "add_to_cart")
    #expect(event.occurTimeMillis == Self.start + 1_000)
    #expect(event.distinctId.hasPrefix("anon-"))
    #expect(event.sessionId.isUUID)
    #expect(event.customProperties == ["productId": .string("p1"), "quantity": .int(2)])
    #expect(event.autoProperties["$projectId"] == .string(Self.project))
  }

  @Test("properties are read during the call")
  func propertiesReadDuringCall() throws {
    final class Counter: CustomStringConvertible {
      var value = 1

      var description: String {
        "\(value)"
      }
    }
    let client = try makeClient { $0.batchMaxSize = 1 }
    let counter = Counter()

    client.track("tick", properties: ["count": counter], options: nil)
    counter.value = 2
    scheduler.runCurrent()

    #expect(try transport.batches.single().single().customProperties == ["count": .string("1")])
  }

  @Test("an untyped well-known event without a required property gets a debug hint")
  func missingRequiredHint() throws {
    let client = try makeClient()

    client.track("add_to_cart", properties: ["price": 10], options: nil)
    client.track("add_to_cart", properties: ["productId": "p1"], options: nil)
    client.track("checkout", properties: nil, options: nil)

    #expect(
      logger.debugs.filter { $0.contains("missing") } == ["Event \"add_to_cart\" is missing its required \"productId\""]
    )
  }

  @Test("a timestamp option sets when the event happened")
  func timestamp() throws {
    let client = try makeClient { $0.batchMaxSize = 1 }

    client.track("imported", properties: nil, options: Pug.TrackOptions(timestamp: Date(timeIntervalSince1970: 0.042)))
    scheduler.runCurrent()

    #expect(try transport.batches.single().single().occurTimeMillis == 42)
  }

  @Test("an invalid kind is dropped")
  func invalidKind() throws {
    let client = try makeClient()

    client.track("add to cart", properties: nil, options: nil)
    client.track(" ", properties: nil, options: nil)
    client.flush()
    scheduler.advanceUntilIdle()

    #expect(transport.batches.isEmpty)
    #expect(logger.warnings.count == 2)
  }

  @Test("an immediate event is sent on its own")
  func immediate() throws {
    let client = try makeClient()

    client.track("queued", properties: nil, options: nil)
    client.track("urgent", properties: nil, options: Pug.TrackOptions(immediate: true))
    scheduler.runCurrent()

    #expect(transport.kinds == [["urgent"]])
  }

  @Test("typed events are mapped from their schema")
  func typed() throws {
    let client = try makeClient { $0.batchMaxSize = 1 }

    client.trackTyped(WellKnownEvents.videoPlay, ["v1", 1.5], extras: ["quality": "hd"], options: nil)
    scheduler.runCurrent()

    let event = try transport.batches.single().single()
    #expect(event.kind == "video_play")
    #expect(
      event.customProperties == ["videoId": .string("v1"), "position": .string("1.5s"), "quality": .string("hd")])
  }

  @Test("nothing is tracked or identified while consent is denied")
  func deniedTracksNothing() throws {
    let client = try makeClient { $0.defaultTrackingConsent = .denied }

    client.track("a", properties: nil, options: nil)
    client.identify("user-1", traits: nil)
    client.rotateSession()
    client.flush()
    scheduler.advanceUntilIdle()

    #expect(transport.batches.isEmpty)
    #expect(transport.identifies.isEmpty)
    #expect(keys.all.allSatisfy { storage.string(forKey: $0) == nil })
    #expect(logger.debugs.contains("Event \"a\" was dropped: tracking consent is denied"))
    #expect(logger.debugs.contains("identify() was dropped: tracking consent is denied"))
  }

  @Test("dryRun logs events and identify without sending them")
  func dryRun() throws {
    let client = try makeClient { $0.dryRun = true }

    client.track("a", properties: nil, options: Pug.TrackOptions(immediate: true))
    client.identify("user-1", traits: nil)
    client.flush()
    scheduler.advanceUntilIdle()

    #expect(transport.batches.isEmpty)
    #expect(transport.identifies.isEmpty)
    #expect(logger.debugs.contains("dryRun: event \"a\" was not sent"))
    #expect(logger.debugs.contains("dryRun: identify() was not sent"))
    #expect(logger.warnings == ["dryRun is on: events and identify() are logged, never sent"])
  }

  @Test("the first identify links the anonymous id, and later events carry the external id")
  func identifyLinks() throws {
    let client = try makeClient { $0.batchMaxSize = 1 }

    client.track("before", properties: nil, options: nil)
    client.identify("user-1", traits: ["plan": "pro"])
    scheduler.runCurrent()
    let anonymousId = try transport.batches.single().single().distinctId
    client.track("after", properties: nil, options: nil)
    client.identify("user-1", traits: nil)
    scheduler.runCurrent()

    #expect(
      transport.identifies == [
        IdentifyRequest(externalId: "user-1", traits: ["plan": .string("pro")], anonymousId: anonymousId),
        IdentifyRequest(externalId: "user-1", traits: [:], anonymousId: nil),
      ]
    )
    #expect(try transport.batches.last?.single().distinctId == "user-1")
    #expect(storage.string(forKey: keys.externalId) == "user-1")
  }

  @Test("a failed identify is logged and leaves the user anonymous")
  func failedIdentify() throws {
    transport.failNextIdentify(.invalidArgument)
    let client = try makeClient()

    client.identify("user-1", traits: nil)
    scheduler.runCurrent()

    #expect(logger.errors == ["identify() failed (invalid_argument: scripted)"])
    #expect(storage.string(forKey: keys.externalId) == nil)
  }

  @Test("identify drops blank and reserved ids")
  func identifyDropsInvalidIds() throws {
    let client = try makeClient()

    client.identify(" ", traits: nil)
    client.identify("cookieless-abc", traits: nil)
    scheduler.runCurrent()

    #expect(transport.identifies.isEmpty)
    #expect(
      logger.errors == [
        "identify() was dropped: externalId is blank",
        "identify() was dropped: externalId may not start with \"cookieless-\"",
      ]
    )
  }

  @Test("a reset during identify wins")
  func resetDuringIdentify() throws {
    let client = try makeClient()
    transport.hold()

    client.identify("user-1", traits: nil)
    scheduler.runCurrent()
    client.reset()
    scheduler.runCurrent()
    transport.releaseAll()
    scheduler.runCurrent()

    #expect(storage.string(forKey: keys.externalId) == nil)
    #expect(logger.debugs.contains("identify() finished after the identity was reset; it was not applied"))
  }

  @Test("an opt-out during identify wins")
  func optOutDuringIdentify() throws {
    let client = try makeClient()
    transport.hold()

    client.identify("user-1", traits: nil)
    scheduler.runCurrent()
    client.optOutTracking()
    client.optInTracking()
    scheduler.runCurrent()
    transport.releaseAll()
    scheduler.runCurrent()

    #expect(storage.string(forKey: keys.externalId) == nil)
    #expect(storage.string(forKey: keys.profile) == nil)
  }

  @Test("the last identify called wins, whichever finishes last")
  func lastIdentifyWins() throws {
    let client = try makeClient()
    transport.hold()

    client.identify("user-1", traits: nil)
    client.identify("user-2", traits: nil)
    scheduler.runCurrent()
    transport.release(1)
    scheduler.runCurrent()
    transport.release(0)
    scheduler.runCurrent()

    #expect(storage.string(forKey: keys.externalId) == "user-2")
    #expect(logger.debugs.contains("identify() finished after a later identify(); the later one stands"))
  }

  @Test("reset starts a new identity and sends what the last user queued")
  func reset() throws {
    let client = try makeClient()
    client.identify("user-1", traits: nil)
    scheduler.runCurrent()
    client.track("before", properties: nil, options: nil)
    scheduler.runCurrent()

    client.reset()
    scheduler.runCurrent()
    client.track("after", properties: nil, options: nil)
    client.flush()
    scheduler.runCurrent()

    let events = try transport.batches.map { try $0.single() }
    try #require(events.count == 2)
    #expect(events[0].kind == "before")
    #expect(events[0].distinctId == "user-1")
    #expect(events[1].distinctId.hasPrefix("anon-"))
    #expect(events[0].sessionId != events[1].sessionId)
    #expect(storage.string(forKey: keys.externalId) == nil)
  }

  @Test("reset while consent is denied clears an identity kept from before")
  func resetWhileDenied() throws {
    storage.setString(#"{"anonymousId":"anon-1","externalId":"user-1"}"#, forKey: keys.profile)
    storage.setString("user-1", forKey: keys.externalId)
    let client = try makeClient { $0.defaultTrackingConsent = .denied }

    client.reset()
    scheduler.runCurrent()

    #expect(storage.string(forKey: keys.profile) == nil)
    #expect(storage.string(forKey: keys.externalId) == nil)
  }

  @Test("rotateSession starts a new session for the same user")
  func rotateSession() throws {
    let client = try makeClient { $0.batchMaxSize = 1 }

    client.track("a", properties: nil, options: nil)
    client.rotateSession()
    client.track("b", properties: nil, options: nil)
    scheduler.runCurrent()

    let events = try transport.batches.map { try $0.single() }
    try #require(events.count == 2)
    #expect(events[0].sessionId != events[1].sessionId)
    #expect(events[0].distinctId == events[1].distinctId)
  }

  @Test("opting out drops queued events unsent and forgets the identity")
  func optOut() throws {
    let client = try makeClient()
    client.identify("user-1", traits: nil)
    client.track("a", properties: nil, options: nil)
    scheduler.runCurrent()

    client.optOutTracking()
    client.flush()
    scheduler.advanceUntilIdle()

    #expect(transport.batches.isEmpty)
    #expect(keys.all.filter { $0 != keys.consent }.allSatisfy { storage.string(forKey: $0) == nil })
    #expect(storage.string(forKey: keys.consent) == "denied")
    #expect(logger.debugs.contains("Dropped 1 event unsent: tracking consent is denied"))
  }

  @Test("opting back in starts a fresh identity")
  func optBackIn() throws {
    let client = try makeClient { $0.batchMaxSize = 1 }
    client.track("a", properties: nil, options: nil)
    scheduler.runCurrent()

    client.optOutTracking()
    client.optInTracking()
    client.track("b", properties: nil, options: nil)
    scheduler.runCurrent()

    let events = try transport.batches.map { try $0.single() }
    try #require(events.count == 2)
    #expect(events[0].distinctId != events[1].distinctId)
    #expect(events[0].sessionId != events[1].sessionId)
  }

  @Test("a stored opt-out purges the stored identity and queue at start")
  func storedOptOut() throws {
    storage.setString("denied", forKey: keys.consent)
    storage.setString(#"{"anonymousId":"anon-1"}"#, forKey: keys.profile)
    storage.setString("[\(EventJSON.encode(event("a")))]", forKey: keys.queue)
    let client = try makeClient()

    scheduler.runCurrent()

    #expect(storage.string(forKey: keys.profile) == nil)
    #expect(storage.string(forKey: keys.queue) == nil)
    #expect(storage.string(forKey: keys.consent) == "denied")
    #expect(client.trackingConsent == .denied)
    #expect(!client.isConsentPending)
    #expect(!client.isTrackingEnabled)
  }

  @Test("the consent getters answer with the latest choice at once")
  func gettersAnswerAtOnce() throws {
    let client = try makeClient()

    client.optOutTracking()

    #expect(client.trackingConsent == .denied)
    #expect(!client.isConsentPending)
    #expect(!client.isTrackingEnabled)
    #expect(logger.warnings.isEmpty)
  }

  @Test("the consent getters report the restored choice once started")
  func gettersReportRestored() throws {
    storage.setString("granted", forKey: keys.consent)
    let client = try makeClient { $0.defaultTrackingConsent = .denied }

    scheduler.runCurrent()

    #expect(client.trackingConsent == .granted)
    #expect(!client.isConsentPending)
    #expect(client.isTrackingEnabled)
  }

  @Test("the consent getters report the default as pending")
  func gettersReportDefault() throws {
    let client = try makeClient()

    scheduler.runCurrent()

    #expect(client.trackingConsent == .granted)
    #expect(client.isConsentPending)
  }

  @Test("the consent getters answer unknown at once before start-up has read consent")
  func gettersBeforeStartUp() throws {
    let client = try makeClient(after: Teardown())

    scheduler.runCurrent()

    #expect(client.trackingConsent == nil)
    #expect(client.isConsentPending)
    #expect(!client.isTrackingEnabled)
    #expect(
      logger.warnings == [
        "Tracking consent was asked for before Pug read it from storage; it is reported as unknown. Ask from "
          + "Pug.whenConsentReady() instead"
      ]
    )
  }

  @Test("a choice made before start-up has read consent wins over the stored one")
  func choiceBeforeStartUp() throws {
    storage.setString("granted", forKey: keys.consent)
    let previous = Teardown()
    let client = try makeClient(after: previous)

    client.optOutTracking()
    previous.finish()
    scheduler.runCurrent()

    #expect(client.trackingConsent == .denied)
    #expect(!client.isConsentPending)
    #expect(storage.string(forKey: keys.consent) == "denied")
  }

  @Test("a consent getter answers for one moment while consent changes on other threads")
  func getterMoment() throws {
    storage.setString("denied", forKey: keys.consent)
    let previous = Teardown()
    let running = Locked<Client?>(nil)
    let isInterleaved = Locked(false)
    // The warning that consent is unknown runs host code inside the getter. There the user opts in, then start-up
    // reads the stored opt-out, which that earlier opt-in overrides.
    let interleaving = HookLogger(base: logger) { [scheduler] message in
      guard message.contains("reported as unknown"), !isInterleaved.withLock({ $0 }) else { return }
      isInterleaved.withLock { $0 = true }
      running.withLock { $0 }?.optInTracking()
      previous.finish()
      scheduler.runCurrent()
    }
    let client = try makeClient(after: previous) { $0.logger = interleaving }
    running.withLock { $0 = client }

    #expect(client.trackingConsent == nil)
    #expect(client.trackingConsent == .granted)
    #expect(storage.string(forKey: keys.consent) == "granted")
  }

  @Test("whenConsentReady runs on the main thread once start-up has read the stored choice")
  @MainActor
  func whenConsentReadyWaits() throws {
    storage.setString("granted", forKey: keys.consent)
    let previous = Teardown()
    let client = try makeClient(after: previous) { $0.defaultTrackingConsent = .denied }
    let seen = Locked<[ConsentAnswer]>([])

    client.whenConsentReady {
      seen.withLock { $0.append(ConsentAnswer(consent: client.trackingConsent, isPending: client.isConsentPending)) }
    }
    scheduler.runCurrent()
    platform.runMainThread()
    #expect(seen.withLock { $0 }.isEmpty)

    previous.finish()
    scheduler.runCurrent()
    #expect(seen.withLock { $0 }.isEmpty)
    platform.runMainThread()

    #expect(seen.withLock { $0 } == [ConsentAnswer(consent: .granted, isPending: false)])
    #expect(logger.warnings.isEmpty)
  }

  @Test("whenConsentReady after start-up runs on the main thread's next turn, once")
  @MainActor
  func whenConsentReadyAfterStartUp() throws {
    let client = try makeClient()
    scheduler.runCurrent()
    let runs = Locked(0)

    client.whenConsentReady { runs.withLock { $0 += 1 } }
    #expect(runs.withLock { $0 } == 0)
    platform.runMainThread()
    platform.runMainThread()

    #expect(runs.withLock { $0 } == 1)
  }

  @Test("whenConsentReady callbacks see what start-up read, even when run at once")
  @MainActor
  func whenConsentReadyAtOnce() throws {
    storage.setString("granted", forKey: keys.consent)
    let client = try makeClient(platform: FakePlatform(runsMainAtOnce: true)) { $0.defaultTrackingConsent = .denied }
    let seen = Locked<[ConsentAnswer]>([])

    client.whenConsentReady {
      seen.withLock { $0.append(ConsentAnswer(consent: client.trackingConsent, isPending: client.isConsentPending)) }
    }
    scheduler.runCurrent()

    #expect(seen.withLock { $0 } == [ConsentAnswer(consent: .granted, isPending: false)])
    #expect(logger.warnings.isEmpty)
  }

  @Test("nothing runs until the previous client's teardown is over, then calls run in order")
  func waitsForPreviousTeardown() throws {
    let previous = Teardown()
    let client = try makeClient(after: previous)

    client.track("a", properties: nil, options: nil)
    client.optOutTracking()
    client.optInTracking()
    client.track("b", properties: nil, options: nil)
    client.flush()
    scheduler.advanceUntilIdle()
    #expect(keys.all.allSatisfy { storage.string(forKey: $0) == nil })
    #expect(transport.batches.isEmpty)
    previous.finish()
    scheduler.runCurrent()

    #expect(transport.kinds == [["b"]])
  }

  @Test("flush sends now, even while a retry is pending")
  func flushDuringRetry() throws {
    transport.failNextBatch(.unavailable)
    let client = try makeClient {
      $0.batchMaxSize = 1
      $0.batchMaxWait = 60
    }

    client.track("a", properties: nil, options: nil)
    scheduler.runCurrent()
    client.flush()
    scheduler.runCurrent()

    #expect(transport.kinds == [["a"], ["a"]])
    #expect(storage.string(forKey: keys.queue) == nil)
  }

  @Test("destroy sends what is queued and keeps the identity")
  func destroySends() throws {
    let client = try makeClient()
    client.identify("user-1", traits: nil)
    client.track("a", properties: nil, options: nil)

    client.destroy()
    scheduler.runCurrent()

    #expect(client.teardown.isFinished)
    #expect(transport.kinds == [["a"]])
    #expect(storage.string(forKey: keys.queue) == nil)
    #expect(storage.string(forKey: keys.externalId) == "user-1")
    #expect(storage.string(forKey: keys.session) != nil)
  }

  @Test("destroy waits for a batch in flight before letting go of storage")
  func destroyWaitsForBatch() throws {
    let client = try makeClient { $0.batchMaxSize = 2 }
    transport.hold()
    client.track("a", properties: nil, options: nil)
    client.track("b", properties: nil, options: nil)
    scheduler.runCurrent()

    client.track("c", properties: nil, options: nil)
    client.destroy()
    scheduler.advanceTime(by: 5_000)
    #expect(!client.teardown.isFinished)
    transport.releaseAll()
    scheduler.runCurrent()

    #expect(client.teardown.isFinished)
    #expect(transport.kinds == [["a", "b"], ["c"]])
    #expect(storage.string(forKey: keys.queue) == nil)
  }

  @Test("destroy waits for an identify and an immediate event in flight")
  func destroyWaitsForIdentify() throws {
    let client = try makeClient()
    transport.hold()
    client.identify("user-1", traits: nil)
    client.track("x", properties: nil, options: Pug.TrackOptions(immediate: true))
    scheduler.runCurrent()

    client.destroy()
    scheduler.advanceTime(by: 5_000)
    #expect(!client.teardown.isFinished)
    transport.releaseAll()
    scheduler.runCurrent()

    #expect(client.teardown.isFinished)
    #expect(storage.string(forKey: keys.externalId) == "user-1")
    #expect(transport.kinds == [["x"]])
    #expect(storage.string(forKey: keys.queue) == nil)
  }

  @Test("an immediate event that destroy stops waiting for is kept")
  func destroyKeepsImmediate() throws {
    let client = try makeClient()
    transport.hold()
    client.track("x", properties: nil, options: Pug.TrackOptions(immediate: true))

    client.destroy()
    scheduler.advanceTime(by: Client.teardownTimeoutMillis)
    scheduler.runCurrent()

    #expect(try stored().map(\.kind) == ["x"])
  }

  @Test("destroy stops waiting for the network after ten seconds and keeps the events")
  func destroyTimesOut() throws {
    let client = try makeClient()
    transport.hold()
    client.track("a", properties: nil, options: nil)

    client.destroy()
    scheduler.advanceTime(by: Client.teardownTimeoutMillis - 1)
    #expect(!client.teardown.isFinished)
    scheduler.advanceTime(by: 1)
    scheduler.runCurrent()
    #expect(client.teardown.isFinished)
    transport.releaseAll()
    scheduler.advanceUntilIdle()

    #expect(try stored().map(\.kind) == ["a"])
    #expect(logger.warnings == ["Pug.destroy() stopped waiting for the network after 10000 ms"])
  }

  @Test("a send failing during destroy is not retried")
  func destroyDoesNotRetry() throws {
    transport.batchFailure = .unavailable
    let client = try makeClient()
    client.track("a", properties: nil, options: nil)

    client.destroy()
    scheduler.advanceUntilIdle()

    #expect(client.teardown.isFinished)
    #expect(transport.batches.count == 1)
    #expect(try stored().map(\.kind) == ["a"])
  }

  @Test("events a destroyed client could not send go out with the next one")
  func nextClientSends() throws {
    transport.batchFailure = .unavailable
    let first = try makeClient()
    first.track("a", properties: nil, options: nil)
    first.destroy()
    scheduler.advanceUntilIdle()
    transport.batchFailure = nil

    let second = try makeClient(after: first.teardown)
    second.flush()
    scheduler.runCurrent()

    #expect(transport.kinds == [["a"], ["a"]])
    #expect(storage.string(forKey: keys.queue) == nil)
  }

  @Test("calls after destroy are ignored")
  func callsAfterDestroy() throws {
    let client = try makeClient()

    client.destroy()
    client.track("late", properties: nil, options: nil)
    scheduler.advanceUntilIdle()

    #expect(transport.batches.isEmpty)
    #expect(logger.debugs.contains("Pug.track() was ignored: Pug was destroyed"))
  }

  @Test("a storage that fails to write falls back to memory and tracking goes on")
  func failingStorage() throws {
    let client = try makeClient {
      $0.storage = UnwritableStorage()
      $0.batchMaxSize = 1
    }

    client.track("a", properties: nil, options: nil)
    scheduler.runCurrent()

    #expect(transport.kinds == [["a"]])
    #expect(logger.warnings == ["Storage failed; state is kept in memory only until the app restarts"])
  }

  @Test("a stored choice that cannot be read keeps tracking off until the user chooses")
  func unreadableConsent() throws {
    struct Unreadable: Error {}
    let client = try makeClient {
      $0.storage = ThrowingStorage(Unreadable())
      $0.batchMaxSize = 1
    }

    client.track("a", properties: nil, options: nil)
    client.identify("user-1", traits: nil)
    scheduler.runCurrent()
    #expect(transport.batches.isEmpty)
    #expect(transport.identifies.isEmpty)
    #expect(client.trackingConsent == .denied)
    #expect(client.isConsentPending)
    client.optInTracking()
    client.track("b", properties: nil, options: nil)
    scheduler.runCurrent()

    #expect(transport.kinds == [["b"]])
    #expect(
      logger.warnings == [
        "Storage failed; state is kept in memory only until the app restarts",
        "The stored tracking consent could not be read, so it is denied until the user chooses: it may be an opt-out",
      ]
    )
  }

  private func makeClient(
    after previous: Teardown? = nil,
    platform: FakePlatform? = nil,
    _ configure: (inout Pug.Options) -> Void = { _ in }
  ) throws -> Client {
    var options = Pug.Options(apiKey: "pub_key")
    options.logger = logger
    options.storage = storage
    options.debug = true
    configure(&options)
    let client = Client(
      configuration: try Configuration(projectId: Self.project, options: options),
      transport: transport,
      scheduler: scheduler,
      clock: scheduler,
      platform: platform ?? self.platform,
      ids: ids,
      random: { 0.5 }
    )
    client.start(after: previous)
    return client
  }

  private func stored() throws -> [Event] {
    let raw = try #require(storage.string(forKey: keys.queue))
    let array = try #require(StoredJSON.parse(raw) as? [Any])
    return try array.map { try #require(EventJSON.decode($0)) }
  }

  private func event(_ kind: String) -> Event {
    Event(
      eventId: "00000000-0000-7000-8000-0000000000ff",
      kind: kind,
      distinctId: "anon-1",
      sessionId: "00000000-0000-7000-8000-0000000000aa",
      occurTimeMillis: Self.start,
      autoProperties: [:],
      customProperties: [:]
    )
  }
}
