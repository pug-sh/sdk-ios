/// Undelivered events, persisted as one JSON array. A batch is sent under a lock: `lock` takes events off the front,
/// then `commit` drops them once delivered or `rollback` puts them back. The stored array always holds the locked
/// batch followed by the pending events, so a process that dies mid-send resends the batch on its next launch.
final class EventQueue {
  final class Batch: Sendable {
    let events: [Event]
    fileprivate let entries: [Entry]

    fileprivate init(_ entries: [Entry]) {
      self.entries = entries
      events = entries.map(\.event)
    }
  }

  // Each event's JSON is kept so that persisting a change joins strings instead of re-encoding every event, which
  // matters when a long offline spell fills the queue.
  fileprivate struct Entry: Sendable {
    let event: Event
    let json: String
    let size: Int

    init(_ event: Event) {
      self.event = event
      json = EventJSON.encode(event)
      size = Wire.eventSize(event)
    }
  }

  private let storage: SafeStorage
  private let key: String
  private let logger: SafeLogger
  private let maxQueueSize: Int
  private var pending: [Entry] = []
  private var lockedBatch: Batch?
  private var overflowWarned = false

  init(storage: SafeStorage, key: String, logger: SafeLogger, maxQueueSize: Int) {
    self.storage = storage
    self.key = key
    self.logger = logger
    self.maxQueueSize = max(maxQueueSize, 0)
    restore()
  }

  /// Events waiting to be sent, not counting a locked batch.
  var pendingCount: Int {
    pending.count
  }

  var totalCount: Int {
    pending.count + (lockedBatch?.entries.count ?? 0)
  }

  /// At capacity the oldest pending event is dropped; with every event locked, the new one is.
  func push(_ event: Event) {
    if totalCount >= maxQueueSize {
      if pending.isEmpty {
        overflow("the new event was dropped")
        return
      }
      pending.removeFirst()
      overflow("the oldest event was dropped")
    }
    pending.append(Entry(event))
    persist()
  }

  /// Locks up to `maxCount` events and `maxBytes` of encoded events from the front, or returns nil while another
  /// batch is locked or nothing is pending. A repeated event id is dropped rather than sent twice in one request,
  /// as is an event that alone exceeds `maxBytes`.
  func lock(maxCount: Int, maxBytes: Int) -> Batch? {
    guard lockedBatch == nil else { return nil }
    var taken: [Entry] = []
    var takenIds: Set<String> = []
    var bytes = 0
    var consumed = 0
    var dropped = 0
    while taken.count < maxCount, consumed < pending.count {
      let next = pending[consumed]
      if takenIds.contains(next.event.eventId) {
        dropped += 1
        logger.warning("A queued event repeating the id of another in its batch was dropped")
      } else if next.size > maxBytes {
        dropped += 1
        logger.error(
          "A queued \"\(next.event.kind)\" event of \(next.size) bytes was dropped: too large to send")
      } else if bytes + next.size > maxBytes {
        break
      } else {
        taken.append(next)
        takenIds.insert(next.event.eventId)
        bytes += next.size
      }
      consumed += 1
    }
    pending.removeFirst(consumed)
    lockedBatch = taken.isEmpty ? nil : Batch(taken)
    if dropped > 0 {
      persist()
    }
    return lockedBatch
  }

  /// Drops the delivered (or permanently rejected) `batch`; a batch from before `clear()` is ignored.
  func commit(_ batch: Batch) {
    guard batch === lockedBatch else { return }
    lockedBatch = nil
    overflowWarned = false
    persist()
  }

  /// Returns `batch` to the front of the queue; a batch from before `clear()` is ignored.
  func rollback(_ batch: Batch) {
    guard batch === lockedBatch else { return }
    pending.insert(contentsOf: batch.entries, at: 0)
    lockedBatch = nil
    // Storage already holds the locked batch ahead of the pending events.
  }

  /// Drops every event, a locked batch included, and returns how many there were.
  @discardableResult
  func clear() -> Int {
    let dropped = totalCount
    pending.removeAll()
    lockedBatch = nil
    overflowWarned = false
    storage.removeValue(forKey: key)
    return dropped
  }

  private func overflow(_ outcome: String) {
    if overflowWarned {
      logger.debug("The event queue is full; \(outcome)")
      return
    }
    overflowWarned = true
    logger.warning(
      "The event queue is full (\(maxQueueSize) events); \(outcome). Later drops are logged at debug level")
  }

  private func persist() {
    let entries = [lockedBatch?.entries ?? [], pending].joined()
    guard !entries.isEmpty else {
      storage.removeValue(forKey: key)
      return
    }
    storage.setString("[" + entries.map(\.json).joined(separator: ",") + "]", forKey: key)
  }

  private func restore() {
    guard let raw = storage.string(forKey: key) else { return }
    guard let stored = StoredJSON.parse(raw) as? [Any] else {
      logger.warning("The stored event queue could not be read and was discarded")
      storage.removeValue(forKey: key)
      return
    }
    var unreadable = 0
    var reserved = 0
    for element in stored {
      guard let event = EventJSON.decode(element) else {
        unreadable += 1
        continue
      }
      if event.distinctId.hasUTF8Prefix(Identity.reservedIdPrefix) {
        reserved += 1
      } else {
        pending.append(Entry(event))
      }
    }
    let excess = max(pending.count - maxQueueSize, 0)
    pending.removeFirst(excess)
    if unreadable > 0 {
      logger.warning("\(unreadable) stored events could not be read and were dropped")
    }
    if reserved > 0 {
      logger.warning(
        "\(reserved) stored events were dropped: their distinct id uses the reserved "
          + "\"\(Identity.reservedIdPrefix)\" prefix, which the server rejects")
    }
    if excess > 0 {
      logger.warning("\(excess) of the oldest stored events were dropped to fit maxQueueSize \(maxQueueSize)")
    }
    if unreadable + reserved + excess > 0 {
      persist()
    }
  }
}
