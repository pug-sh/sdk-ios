import Foundation
import Testing

@testable import Pug

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct EventDispatcherTests {
  private static let key = "__pug_proj_1_queue__"
  private static let minute: Int64 = 60_000

  private let scheduler: TestScheduler
  private let transport: FakeTransport
  private let storage = Pug.MemoryStorage()
  private let logger = RecordingLogger()

  init() {
    let scheduler = TestScheduler()
    self.scheduler = scheduler
    transport = FakeTransport { scheduler.currentTime }
  }

  @Test("a full batch is sent at once")
  func fullBatch() {
    let dispatcher = makeDispatcher()
    let events = events(0..<3)

    events.forEach(dispatcher.enqueue)
    scheduler.runCurrent()

    #expect(transport.batches == [events])
    #expect(transport.batchTimes == [0])
    #expect(storage.string(forKey: Self.key) == nil)
  }

  @Test("fewer events go out maxWaitMillis after the first of them")
  func waitForMore() {
    let dispatcher = makeDispatcher(maxWaitMillis: 5_000)

    dispatcher.enqueue(event(0))
    scheduler.advanceTime(by: 4_000)
    dispatcher.enqueue(event(1))
    scheduler.advanceTime(by: 999)
    #expect(transport.batches.isEmpty)
    scheduler.advanceTime(by: 1)
    scheduler.runCurrent()

    #expect(transport.batches == [events(0..<2)])
    #expect(transport.batchTimes == [5_000])
  }

  @Test("one batch is in flight at a time, and a full queue keeps sending")
  func oneBatchInFlight() throws {
    let dispatcher = makeDispatcher()
    transport.hold()

    events(0..<7).forEach(dispatcher.enqueue)
    scheduler.runCurrent()
    #expect(transport.batches.count == 1)
    transport.releaseAll()
    scheduler.runCurrent()

    #expect(transport.batches == [events(0..<3), events(3..<6)])
    #expect(try stored() == [event(6)])
  }

  @Test("a transient failure keeps the batch and retries with exponential backoff")
  func exponentialBackoff() throws {
    transport.batchFailure = .unavailable
    let dispatcher = makeDispatcher(maxWaitMillis: 5_000)
    let events = events(0..<3)

    events.forEach(dispatcher.enqueue)
    scheduler.advanceTime(by: 20 * Self.minute)

    // 5 s doubling to the 5-minute cap.
    #expect(transport.batchTimes == [0, 5_000, 15_000, 35_000, 75_000, 155_000, 315_000, 615_000, 915_000])
    #expect(try stored() == events)
    #expect(
      logger.warnings == [
        "Sending 3 events failed (unavailable: scripted); retrying in 5000 ms. Until a send succeeds, failures are "
          + "logged at debug level"
      ]
    )
    #expect(logger.debugs.contains("Sending 3 events failed (unavailable: scripted); retrying in 300000 ms"))
  }

  @Test("retries start from a one-second floor")
  func retryFloor() {
    transport.batchFailure = .unavailable
    let dispatcher = makeDispatcher(maxWaitMillis: 0)

    dispatcher.enqueue(event(0))
    scheduler.advanceTime(by: 8_000)

    #expect(transport.batchTimes == [0, 1_000, 3_000, 7_000])
  }

  @Test("a retry can come up to a fifth early")
  func earlyJitter() {
    transport.failNextBatch(.unavailable)
    let dispatcher = makeDispatcher(maxWaitMillis: 10_000, random: 0)

    events(0..<3).forEach(dispatcher.enqueue)
    scheduler.advanceUntilIdle()

    #expect(transport.batchTimes == [0, 8_000])
  }

  @Test("a retry can come up to a fifth late")
  func lateJitter() {
    transport.failNextBatch(.unavailable)
    let dispatcher = makeDispatcher(maxWaitMillis: 10_000, random: 1)

    events(0..<3).forEach(dispatcher.enqueue)
    scheduler.advanceUntilIdle()

    #expect(transport.batchTimes == [0, 12_000])
  }

  @Test("size triggers wait out a retry")
  func sizeTriggersWait() {
    transport.failNextBatch(.unavailable)
    let dispatcher = makeDispatcher(maxWaitMillis: 1_000)

    events(0..<3).forEach(dispatcher.enqueue)
    scheduler.runCurrent()
    events(3..<6).forEach(dispatcher.enqueue)
    scheduler.advanceTime(by: 999)
    #expect(transport.batches.count == 1)
    scheduler.advanceTime(by: 1)
    scheduler.runCurrent()

    #expect(transport.batches == [events(0..<3), events(0..<3), events(3..<6)])
    #expect(transport.batchTimes == [0, 1_000, 1_000])
  }

  @Test("a success resets the backoff")
  func successResetsBackoff() {
    transport.failNextBatch(.unavailable)
    transport.failNextBatch(.unavailable)
    let dispatcher = makeDispatcher(maxWaitMillis: 1_000)

    events(0..<3).forEach(dispatcher.enqueue)
    scheduler.advanceTime(by: 3_000)
    scheduler.runCurrent()
    transport.failNextBatch(.unavailable)
    events(3..<6).forEach(dispatcher.enqueue)
    scheduler.advanceTime(by: 1_000)
    scheduler.runCurrent()

    #expect(transport.batchTimes == [0, 1_000, 3_000, 3_000, 4_000])
    #expect(storage.string(forKey: Self.key) == nil)
    #expect(logger.warnings.count == 2)
  }

  @Test("an answer from the server ends the wait for a retry")
  func answerEndsRetryWait() {
    transport.batchFailure = .unavailable
    let dispatcher = makeDispatcher(maxWaitMillis: 1_000)

    dispatcher.sendNow(event(0))
    scheduler.advanceTime(by: 3_000)
    scheduler.runCurrent()
    transport.batchFailure = nil
    dispatcher.sendNow(event(1))
    scheduler.advanceTime(by: 1_000)
    scheduler.runCurrent()

    // The next retry was due at 7 s; event 0 goes out maxWaitMillis after the server answered instead.
    #expect(transport.batchTimes == [0, 1_000, 3_000, 3_000, 4_000])
    #expect(transport.batches.last == [event(0)])
    #expect(storage.string(forKey: Self.key) == nil)
  }

  @Test("a permanent failure drops the batch")
  func permanentFailure() {
    transport.failNextBatch(.invalidArgument)
    let dispatcher = makeDispatcher()

    events(0..<3).forEach(dispatcher.enqueue)
    scheduler.advanceUntilIdle()

    #expect(transport.batches.count == 1)
    #expect(storage.string(forKey: Self.key) == nil)
    #expect(logger.errors == ["3 events dropped: rejected by the server (invalid_argument: scripted)"])
  }

  @Test("a short acceptance is reported")
  func shortAcceptance() {
    transport.answerNextBatch(BatchCreateResponse(accepted: 1, droppedByReason: ["salt_unavailable": 2]))
    let dispatcher = makeDispatcher()

    events(0..<3).forEach(dispatcher.enqueue)
    scheduler.runCurrent()

    #expect(logger.warnings == ["The server accepted 1 of 3 events (dropped: salt_unavailable: 2)"])
    #expect(storage.string(forKey: Self.key) == nil)
  }

  @Test("the first three invalid events are named by their kind, with the rules they broke")
  func invalidEvents() {
    let invalid = [
      InvalidEvent(index: 0, violations: ["event.session_id: value must be a valid UUID", "and 2 more"]),
      InvalidEvent(index: 2, violations: ["event.event_id: repeats the event at index 1"]),
      InvalidEvent(index: 7, violations: ["event.kind: value is required"]),
      InvalidEvent(index: 1, violations: ["event.kind: value is required"]),
    ]
    transport.answerNextBatch(
      BatchCreateResponse(accepted: 1, droppedByReason: ["invalid_event": 4], invalidEvents: invalid))
    let dispatcher = makeDispatcher(maxSize: 5)

    events(0..<5).forEach(dispatcher.enqueue)
    scheduler.runCurrent()

    #expect(
      logger.warnings == [
        "The server accepted 1 of 5 events (dropped: invalid_event: 4). Invalid events: \"event_0\": "
          + "event.session_id: value must be a valid UUID; and 2 more | \"event_2\": event.event_id: repeats the event "
          + "at index 1 | event 7: event.kind: value is required | and 1 more"
      ]
    )
    #expect(storage.string(forKey: Self.key) == nil)
  }

  @Test("an immediate event the server finds invalid is named in the warning")
  func invalidImmediateEvent() {
    transport.answerNextBatch(
      BatchCreateResponse(
        accepted: 0,
        droppedByReason: ["invalid_event": 1],
        invalidEvents: [InvalidEvent(index: 0, violations: ["event.kind: value is required"])]
      )
    )
    let dispatcher = makeDispatcher()

    dispatcher.sendNow(event(0))
    scheduler.runCurrent()

    #expect(
      logger.warnings == [
        "The server accepted 0 of 1 event (dropped: invalid_event: 1). Invalid events: \"event_0\": event.kind: "
          + "value is required"
      ]
    )
    #expect(storage.string(forKey: Self.key) == nil)
  }

  @Test("an acknowledgement that cannot be read still delivers the batch, with a warning that drops go unreported")
  func unreadableAcknowledgement() {
    transport.answerNextBatch(nil)
    let dispatcher = makeDispatcher()

    events(0..<3).forEach(dispatcher.enqueue)
    scheduler.runCurrent()

    #expect(storage.string(forKey: Self.key) == nil)
    #expect(
      logger.warnings == [
        "Sent 3 events, but the server's answer could not be read: any events it dropped are not reported"
      ]
    )
  }

  @Test("the network error behind a failure is logged with it")
  func underlyingError() throws {
    transport.failNextBatch(
      with: TransportError(.unavailable, "offline", underlying: URLError(.notConnectedToInternet)))
    let dispatcher = makeDispatcher()

    events(0..<3).forEach(dispatcher.enqueue)
    scheduler.runCurrent()

    let warning = try #require(logger.entries.first { $0.level == "warning" })
    #expect(warning.message.hasPrefix("Sending 3 events failed (unavailable: offline); retrying in"))
    #expect((warning.error as? URLError)?.code == .notConnectedToInternet)
  }

  @Test("flush sends what is pending now, but not during a retry wait")
  func flush() throws {
    let dispatcher = makeDispatcher(maxWaitMillis: 60_000)

    dispatcher.enqueue(event(0))
    dispatcher.flush()
    scheduler.runCurrent()
    #expect(transport.batches == [[event(0)]])

    transport.failNextBatch(.unavailable)
    dispatcher.enqueue(event(1))
    dispatcher.flush()
    scheduler.runCurrent()
    dispatcher.flush()
    scheduler.runCurrent()

    #expect(transport.batches.count == 2)
    #expect(try stored() == [event(1)])
  }

  @Test("drain sends everything, backoff or not")
  func drainSendsEverything() {
    transport.failNextBatch(.unavailable)
    let dispatcher = makeDispatcher(maxWaitMillis: 60_000)

    events(0..<7).forEach(dispatcher.enqueue)
    scheduler.runCurrent()
    let drained = drain(dispatcher)
    scheduler.runCurrent()

    #expect(drained.withLock { $0 })
    #expect(transport.batches == [events(0..<3), events(0..<3), events(3..<6), events(6..<7)])
    #expect(storage.string(forKey: Self.key) == nil)
    scheduler.advanceUntilIdle()
    #expect(transport.batches.count == 4)
  }

  @Test("a drain ends at the first failure")
  func drainEndsAtFailure() throws {
    transport.batchFailure = .unavailable
    let dispatcher = makeDispatcher()

    events(0..<2).forEach(dispatcher.enqueue)
    let drained = drain(dispatcher)
    scheduler.runCurrent()

    #expect(drained.withLock { $0 })
    #expect(transport.batches.count == 1)
    #expect(try stored() == events(0..<2))
  }

  @Test("a drain of an empty queue completes on the worker, after the call")
  func drainOfNothing() {
    let dispatcher = makeDispatcher()

    let drained = drain(dispatcher)
    #expect(!drained.withLock { $0 })
    scheduler.runCurrent()

    #expect(drained.withLock { $0 })
    #expect(transport.batches.isEmpty)
  }

  @Test("a drain waits for the immediate events in flight")
  func drainWaitsForImmediateEvents() throws {
    let dispatcher = makeDispatcher()
    transport.hold()

    dispatcher.enqueue(event(0))
    dispatcher.sendNow(event(1))
    let drained = drain(dispatcher)
    scheduler.runCurrent()
    transport.release(1)
    scheduler.runCurrent()
    #expect(!drained.withLock { $0 })
    transport.batchFailure = .unavailable
    transport.release(0)
    scheduler.runCurrent()

    #expect(drained.withLock { $0 })
    #expect(transport.batches == [[event(1)], [event(0)]])
    #expect(try stored() == [event(1)])
  }

  @Test("disposing completes a drain still waiting")
  func disposeCompletesDrain() {
    let dispatcher = makeDispatcher()
    transport.hold()

    events(0..<3).forEach(dispatcher.enqueue)
    let drained = drain(dispatcher)
    dispatcher.dispose()
    scheduler.runCurrent()

    #expect(drained.withLock { $0 })
  }

  @Test("an immediate event is sent alone right away")
  func immediateEvent() throws {
    let dispatcher = makeDispatcher()

    dispatcher.enqueue(event(0))
    dispatcher.sendNow(event(1))
    scheduler.runCurrent()

    #expect(transport.batches == [[event(1)]])
    #expect(try stored() == [event(0)])
  }

  @Test("an immediate event that fails transiently joins the queue")
  func immediateTransientFailure() throws {
    transport.failNextBatch(.unavailable)
    let dispatcher = makeDispatcher(maxWaitMillis: 1_000)

    dispatcher.sendNow(event(0))
    scheduler.runCurrent()
    #expect(try stored() == [event(0)])
    scheduler.advanceTime(by: 1_000)
    scheduler.runCurrent()

    #expect(transport.batches == [[event(0)], [event(0)]])
    #expect(storage.string(forKey: Self.key) == nil)
  }

  @Test("an immediate event that fails permanently is dropped")
  func immediatePermanentFailure() {
    transport.failNextBatch(.permissionDenied)
    let dispatcher = makeDispatcher()

    dispatcher.sendNow(event(0))
    scheduler.advanceUntilIdle()

    #expect(transport.batches.count == 1)
    #expect(storage.string(forKey: Self.key) == nil)
    #expect(logger.errors == ["1 event dropped: rejected by the server (permission_denied: scripted)"])
  }

  @Test("an immediate event that fails after the queue was cleared is not queued again")
  func immediateFailureAfterClear() {
    let dispatcher = makeDispatcher()
    transport.hold()

    dispatcher.sendNow(event(0))
    scheduler.runCurrent()
    dispatcher.clear()
    transport.batchFailure = .unavailable
    transport.releaseAll()
    scheduler.advanceUntilIdle()

    #expect(storage.string(forKey: Self.key) == nil)
    #expect(transport.batches.count == 1)
  }

  @Test("a batch in flight when the queue is cleared is not put back")
  func clearedBatchNotPutBack() {
    let dispatcher = makeDispatcher()
    transport.hold()

    events(0..<3).forEach(dispatcher.enqueue)
    scheduler.runCurrent()
    #expect(dispatcher.clear() == 3)
    transport.failNextBatch(.unavailable)
    transport.releaseAll()
    scheduler.runCurrent()

    #expect(storage.string(forKey: Self.key) == nil)
    #expect(dispatcher.undelivered == 0)
  }

  @Test("a batch in flight when the queue is cleared does not back off")
  func clearedBatchNoBackoff() {
    let dispatcher = makeDispatcher()
    transport.hold()

    events(0..<3).forEach(dispatcher.enqueue)
    scheduler.runCurrent()
    dispatcher.clear()
    transport.failNextBatch(.unavailable)
    transport.releaseAll()
    scheduler.runCurrent()
    events(3..<6).forEach(dispatcher.enqueue)
    scheduler.runCurrent()

    #expect(transport.batches == [events(0..<3), events(3..<6)])
    #expect(logger.warnings.isEmpty)
  }

  @Test("an immediate event in flight at dispose stays stored")
  func immediateEventAtDispose() throws {
    let dispatcher = makeDispatcher()
    transport.hold()

    dispatcher.sendNow(event(0))
    scheduler.runCurrent()
    dispatcher.dispose()

    #expect(try stored() == [event(0)])
    #expect(dispatcher.undelivered == 1)
  }

  @Test("an immediate event in flight when the queue is cleared is not stored at dispose")
  func clearedImmediateEventAtDispose() {
    let dispatcher = makeDispatcher()
    transport.hold()

    dispatcher.sendNow(event(0))
    scheduler.runCurrent()
    dispatcher.clear()
    dispatcher.dispose()

    #expect(storage.string(forKey: Self.key) == nil)
  }

  @Test("restored events go out maxWaitMillis after start")
  func restoredEvents() {
    makeQueue().push(event(0))
    let dispatcher = makeDispatcher(maxWaitMillis: 5_000)

    dispatcher.start()
    scheduler.advanceTime(by: 5_000)
    scheduler.runCurrent()

    #expect(transport.batches == [[event(0)]])
    #expect(transport.batchTimes == [5_000])
  }

  @Test("close stops timed sends, and queued events stay stored")
  func closeStopsTimedSends() throws {
    let dispatcher = makeDispatcher()

    dispatcher.enqueue(event(0))
    dispatcher.close()
    scheduler.advanceUntilIdle()

    #expect(transport.batches.isEmpty)
    #expect(try stored() == [event(0)])
  }

  @Test("a failure after close is not retried")
  func failureAfterClose() throws {
    transport.batchFailure = .unavailable
    let dispatcher = makeDispatcher()

    dispatcher.enqueue(event(0))
    dispatcher.close()
    _ = drain(dispatcher)
    scheduler.advanceUntilIdle()

    #expect(transport.batches.count == 1)
    #expect(try stored() == [event(0)])
    #expect(logger.warnings == ["Sending 1 event failed (unavailable: scripted); kept in the queue"])
  }

  @Test("a send that finishes after dispose leaves the queue alone")
  func sendAfterDispose() throws {
    let dispatcher = makeDispatcher()
    transport.hold()

    events(0..<3).forEach(dispatcher.enqueue)
    scheduler.runCurrent()
    dispatcher.dispose()
    let stored = try #require(storage.string(forKey: Self.key))
    transport.releaseAll()
    scheduler.advanceUntilIdle()

    #expect(storage.string(forKey: Self.key) == stored)
    #expect(dispatcher.undelivered == 3)
  }

  private func makeDispatcher(maxSize: Int = 3, maxWaitMillis: Int64 = 5_000, random: Double = 0.5) -> EventDispatcher {
    EventDispatcher(
      queue: makeQueue(),
      transport: transport,
      logger: logger.safe(),
      scheduler: scheduler,
      maxSize: maxSize,
      maxWaitMillis: maxWaitMillis,
      random: { random }
    )
  }

  private func makeQueue() -> EventQueue {
    EventQueue(
      storage: SafeStorage(storage, logger: logger.safe()),
      key: Self.key,
      logger: logger.safe(),
      maxQueueSize: 100
    )
  }

  private func drain(_ dispatcher: EventDispatcher) -> Locked<Bool> {
    let drained = Locked(false)
    dispatcher.drain { drained.withLock { $0 = true } }
    return drained
  }

  private func stored() throws -> [Event] {
    let raw = try #require(storage.string(forKey: Self.key))
    let array = try #require(StoredJSON.parse(raw) as? [Any])
    return try array.map { try #require(EventJSON.decode($0)) }
  }

  private func events(_ range: Range<Int>) -> [Event] {
    range.map(event)
  }

  private func event(_ index: Int) -> Event {
    let digits = String(index + 1, radix: 16)
    return Event(
      eventId: "00000000-0000-7000-8000-" + String(repeating: "0", count: 12 - digits.count) + digits,
      kind: "event_\(index)",
      distinctId: "anon-1",
      sessionId: "00000000-0000-7000-8000-0000000000aa",
      occurTimeMillis: 1_760_000_000_000 + Int64(index),
      autoProperties: [:],
      customProperties: [:]
    )
  }
}
