import Testing

@testable import Pug

struct EventQueueTests {
  private static let key = "__pug_proj_1_queue__"

  private let memory = Pug.MemoryStorage()
  private let logger = RecordingLogger()

  @Test("a locked batch is removed on commit")
  func commit() throws {
    let queue = makeQueue()
    let events = (0..<3).map { event($0) }
    events.forEach(queue.push)

    let batch = try #require(queue.lock(maxCount: 2, maxBytes: Limits.maxBatchBytes))

    #expect(batch.events == Array(events.prefix(2)))
    #expect(queue.pendingCount == 1)
    #expect(queue.totalCount == 3)
    queue.commit(batch)
    #expect(queue.totalCount == 1)
    #expect(try stored() == [events[2]])
  }

  @Test("a rolled back batch returns to the front in order")
  func rollback() throws {
    let queue = makeQueue()
    let events = (0..<3).map { event($0) }
    events.forEach(queue.push)

    let batch = try #require(queue.lock(maxCount: 2, maxBytes: Limits.maxBatchBytes))
    queue.push(event(3))
    queue.rollback(batch)

    let next = try #require(queue.lock(maxCount: 10, maxBytes: Limits.maxBatchBytes))
    #expect(next.events == events + [event(3)])
  }

  @Test("only one batch is locked at a time")
  func oneLockAtATime() throws {
    let queue = makeQueue()
    queue.push(event(0))
    queue.push(event(1))

    let batch = try #require(queue.lock(maxCount: 1, maxBytes: Limits.maxBatchBytes))

    #expect(queue.lock(maxCount: 1, maxBytes: Limits.maxBatchBytes) == nil)
    queue.commit(batch)
    #expect(queue.lock(maxCount: 1, maxBytes: Limits.maxBatchBytes) != nil)
  }

  @Test("nothing to lock in an empty queue")
  func emptyQueue() {
    #expect(makeQueue().lock(maxCount: 10, maxBytes: Limits.maxBatchBytes) == nil)
  }

  @Test("a full queue drops its oldest pending event")
  func dropsOldest() throws {
    let queue = makeQueue(maxQueueSize: 3)
    let events = (0..<5).map { event($0) }

    events.forEach(queue.push)

    #expect(try stored() == Array(events.suffix(3)))
    #expect(
      logger.warnings == [
        "The event queue is full (3 events); the oldest event was dropped. Later drops are logged at debug "
          + "level"
      ]
    )
    #expect(logger.debugs == ["The event queue is full; the oldest event was dropped"])
  }

  @Test("a full queue with everything in flight drops the new event")
  func dropsNewWhenAllLocked() throws {
    let queue = makeQueue(maxQueueSize: 2)
    queue.push(event(0))
    queue.push(event(1))
    let batch = try #require(queue.lock(maxCount: 2, maxBytes: Limits.maxBatchBytes))

    queue.push(event(2))

    #expect(queue.totalCount == 2)
    queue.rollback(batch)
    #expect(queue.lock(maxCount: 10, maxBytes: Limits.maxBatchBytes)?.events == [event(0), event(1)])
    #expect(logger.warnings.count == 1)
    #expect(logger.warnings.first?.contains("the new event was dropped") == true)
  }

  @Test("a full queue warns again after it drains")
  func warnsAgainAfterDraining() throws {
    let queue = makeQueue(maxQueueSize: 1)
    queue.push(event(0))
    queue.push(event(1))
    queue.commit(try #require(queue.lock(maxCount: 1, maxBytes: Limits.maxBatchBytes)))

    queue.push(event(2))
    queue.push(event(3))

    #expect(logger.warnings.count == 2)
  }

  @Test("the queue survives a restart, in-flight batch first")
  func survivesARestart() {
    let queue = makeQueue()
    let events = (0..<3).map { event($0) }
    events.forEach(queue.push)
    _ = queue.lock(maxCount: 1, maxBytes: Limits.maxBatchBytes)
    queue.push(event(3))

    let restored = makeQueue()

    #expect(restored.lock(maxCount: 10, maxBytes: Limits.maxBatchBytes)?.events == events + [event(3)])
  }

  @Test("an empty queue leaves nothing in storage")
  func emptyLeavesNothing() throws {
    let queue = makeQueue()
    queue.push(event(0))

    queue.commit(try #require(queue.lock(maxCount: 1, maxBytes: Limits.maxBatchBytes)))

    #expect(memory.string(forKey: Self.key) == nil)
  }

  @Test("clearing drops everything, the locked batch included")
  func clear() throws {
    let queue = makeQueue()
    (0..<3).map { event($0) }.forEach(queue.push)
    let batch = try #require(queue.lock(maxCount: 2, maxBytes: Limits.maxBatchBytes))

    #expect(queue.clear() == 3)

    #expect(queue.totalCount == 0)
    #expect(memory.string(forKey: Self.key) == nil)
    queue.rollback(batch)
    queue.commit(batch)
    #expect(queue.totalCount == 0)
    #expect(memory.string(forKey: Self.key) == nil)
  }

  @Test("a batch from before a clear cannot touch the queue after it")
  func staleBatch() throws {
    let queue = makeQueue()
    queue.push(event(0))
    let stale = try #require(queue.lock(maxCount: 1, maxBytes: Limits.maxBatchBytes))
    queue.clear()
    queue.push(event(1))
    let current = try #require(queue.lock(maxCount: 1, maxBytes: Limits.maxBatchBytes))

    queue.commit(stale)

    #expect(queue.totalCount == 1)
    queue.rollback(current)
    #expect(queue.lock(maxCount: 10, maxBytes: Limits.maxBatchBytes)?.events == [event(1)])
  }

  @Test("a batch stops before exceeding the byte budget")
  func byteBudget() throws {
    let queue = makeQueue()
    let events = (0..<4).map { event($0) }
    events.forEach(queue.push)
    let size = Wire.eventSize(events[0])

    let batch = try #require(queue.lock(maxCount: 10, maxBytes: 3 * size - 1))

    #expect(batch.events == Array(events.prefix(2)))
    #expect(queue.pendingCount == 2)
    #expect(
      Wire.encodeBatchCreateRequest(batch.events).count == batch.events.map(Wire.eventSize).reduce(0, +)
    )
  }

  @Test("an event that alone exceeds the byte budget is dropped")
  func oversizedEvent() throws {
    let queue = makeQueue()
    let large = event(0, custom: ["blob": .string(String(repeating: "x", count: 1_000))])
    queue.push(large)
    queue.push(event(1))

    let batch = try #require(queue.lock(maxCount: 10, maxBytes: Wire.eventSize(large) - 1))

    #expect(batch.events == [event(1)])
    #expect(queue.totalCount == 1)
    #expect(logger.errors.count == 1)
    #expect(logger.errors.first?.hasPrefix("A queued \"kind_0\" event of") == true)
    #expect(try stored() == [event(1)])
  }

  @Test("a repeated event id is not sent twice in one batch")
  func repeatedEventId() throws {
    let queue = makeQueue()
    queue.push(event(0))
    queue.push(event(0))
    queue.push(event(1))

    let batch = try #require(queue.lock(maxCount: 10, maxBytes: Limits.maxBatchBytes))

    #expect(batch.events == [event(0), event(1)])
    #expect(try stored() == [event(0), event(1)])
    #expect(logger.warnings.count == 1)
  }

  @Test("unreadable stored queues are discarded")
  func unreadableQueues() {
    for raw in ["not json", "{}", #""string""#] {
      memory.setString(raw, forKey: Self.key)

      let queue = makeQueue()

      #expect(queue.totalCount == 0)
      #expect(memory.string(forKey: Self.key) == nil)
    }
    #expect(
      logger.warnings == Array(repeating: "The stored event queue could not be read and was discarded", count: 3)
    )
  }

  @Test("unreadable stored events are skipped and the rest kept")
  func unreadableEvents() throws {
    let good = [event(0), event(1)]
    memory.setString(
      "[\(EventJSON.encode(good[0])),\"garbage\",{\"eventId\":\"x\"},\(EventJSON.encode(good[1]))]",
      forKey: Self.key
    )

    let queue = makeQueue()

    #expect(queue.lock(maxCount: 10, maxBytes: Limits.maxBatchBytes)?.events == good)
    #expect(logger.warnings == ["2 stored events could not be read and were dropped"])
    #expect(try stored() == good)
  }

  @Test("stored events with a reserved distinct id are dropped")
  func reservedDistinctIds() throws {
    let healthy = event(0)
    var poisoned = event(1)
    poisoned.distinctId = "cookieless-abc"
    memory.setString("[\(EventJSON.encode(poisoned)),\(EventJSON.encode(healthy))]", forKey: Self.key)

    let queue = makeQueue()

    #expect(queue.totalCount == 1)
    #expect(try stored() == [healthy])
    #expect(logger.warnings.count == 1)
    #expect(
      logger.warnings.first?.hasPrefix("1 stored events were dropped: their distinct id uses the reserved")
        == true
    )
  }

  @Test("a stored queue larger than the limit keeps its newest events")
  func oversizedStoredQueue() {
    let events = (0..<5).map { event($0) }
    memory.setString("[" + events.map(EventJSON.encode).joined(separator: ",") + "]", forKey: Self.key)

    let queue = makeQueue(maxQueueSize: 3)

    #expect(queue.lock(maxCount: 10, maxBytes: Limits.maxBatchBytes)?.events == Array(events.suffix(3)))
    #expect(logger.warnings == ["2 of the oldest stored events were dropped to fit maxQueueSize 3"])
  }

  @Test("a healthy stored queue is not rewritten on load")
  func healthyQueueNotRewritten() {
    let raw = "[" + (0..<2).map { EventJSON.encode(event($0)) }.joined(separator: ",") + "]"
    memory.setString(raw, forKey: Self.key)

    _ = makeQueue()

    #expect(memory.string(forKey: Self.key) == raw)
    #expect(logger.entries.isEmpty)
  }

  private func makeQueue(maxQueueSize: Int = 1_000) -> EventQueue {
    EventQueue(
      storage: SafeStorage(memory, logger: logger.safe()),
      key: Self.key,
      logger: logger.safe(),
      maxQueueSize: maxQueueSize
    )
  }

  private func stored() throws -> [Event] {
    guard let raw = memory.string(forKey: Self.key) else { return [] }
    let array = try #require(StoredJSON.parse(raw) as? [Any])
    return try array.map { try #require(EventJSON.decode($0)) }
  }

  private func event(_ index: Int, custom: [String: PropertyValue] = [:]) -> Event {
    let digits = String(index, radix: 16)
    var properties = custom
    properties["index"] = .int(Int64(index))
    return Event(
      eventId: "00000000-0000-7000-8000-" + String(repeating: "0", count: 12 - digits.count) + digits,
      kind: "kind_\(index)",
      distinctId: "anon-1",
      sessionId: "00000000-0000-7000-8000-0000000000aa",
      occurTimeMillis: 1_760_000_000_000 + Int64(index),
      autoProperties: ["$platform": .string("ios")],
      customProperties: properties
    )
  }
}
