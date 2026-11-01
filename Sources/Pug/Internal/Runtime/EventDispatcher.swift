/// Delivers queued events: a batch goes out once `maxSize` are pending, `maxWaitMillis` after the first of them, or on
/// request, one at a time. A transient failure puts the batch back and retries it with exponential backoff, which size
/// triggers wait out; a permanent one drops it. Confined to the worker, which the transport's answers hop back to.
final class EventDispatcher: @unchecked Sendable {
  static let retryFloorMillis: Int64 = 1_000
  static let retryCapMillis: Int64 = 5 * 60 * 1_000
  private static let retryJitter = 0.2

  private struct ImmediateSend {
    let id: Int
    let event: Event
    let generation: Int
  }

  private let queue: EventQueue
  private let transport: any Transport
  private let logger: SafeLogger
  private let scheduler: any Scheduler
  private let maxSize: Int
  private let maxWaitMillis: Int64
  private let random: @Sendable () -> Double
  private var sending = false
  private var draining = false
  private var drainCompletions: [@Sendable () -> Void] = []
  private var timer: (any Cancellable)?
  private var failures = 0
  // Immediate events awaiting their answer, which dispose() puts back in the queue.
  private var immediateSends: [ImmediateSend] = []
  private var nextImmediateId = 0
  // Bumped by clear(), so that a send answered after a purge does not refill the queue.
  private var generation = 0
  private var closed = false
  private var disposed = false

  /// `random` returns a number in 0...1, which spreads retries 20 % either way.
  init(
    queue: EventQueue,
    transport: any Transport,
    logger: SafeLogger,
    scheduler: any Scheduler,
    maxSize: Int,
    maxWaitMillis: Int64,
    random: @escaping @Sendable () -> Double = { .random(in: 0...1) }
  ) {
    self.queue = queue
    self.transport = transport
    self.logger = logger
    self.scheduler = scheduler
    self.maxSize = max(maxSize, 1)
    self.maxWaitMillis = max(maxWaitMillis, 0)
    self.random = random
  }

  /// Events not yet delivered, a batch in flight included.
  var undelivered: Int {
    queue.totalCount
  }

  /// Events restored from storage go out `maxWaitMillis` after start, like new ones.
  func start() {
    assert(scheduler.isOnWorker)
    if queue.pendingCount > 0 {
      schedule(after: maxWaitMillis)
    }
  }

  func enqueue(_ event: Event) {
    assert(scheduler.isOnWorker)
    queue.push(event)
    if queue.pendingCount >= maxSize, failures == 0 {
      send()
    } else {
      schedule(after: maxWaitMillis)
    }
  }

  /// Sends `event` on its own right away. It joins the queue only if that fails transiently.
  func sendNow(_ event: Event) {
    assert(scheduler.isOnWorker)
    let immediate = ImmediateSend(id: nextImmediateId, event: event, generation: generation)
    nextImmediateId &+= 1
    immediateSends.append(immediate)
    transport.sendBatch([event]) { [self] result in
      scheduler.run { [self] in sent(immediate, result) }
    }
  }

  /// Sends the pending events now, unless a retry is being waited out.
  func flush() {
    assert(scheduler.isOnWorker)
    if failures == 0 {
      send()
    }
  }

  /// Sends every pending event, backoff or not. `completion` runs on the worker once nothing is in flight: the queue
  /// is empty or a send failed, and every immediate event has its answer. Disposing runs it too.
  func drain(then completion: @escaping @Sendable () -> Void) {
    assert(scheduler.isOnWorker)
    drainCompletions.append(completion)
    draining = true
    send()
  }

  /// Drops every event, a batch in flight included, and returns how many there were.
  @discardableResult
  func clear() -> Int {
    assert(scheduler.isOnWorker)
    generation &+= 1
    cancelTimer()
    return queue.clear()
  }

  /// Stops timed sends and retries. Sends in flight still settle, and what stays queued stays stored.
  func close() {
    assert(scheduler.isOnWorker)
    closed = true
    cancelTimer()
  }

  /// From here on nothing touches the queue, whose storage may then belong to the next client. Immediate events still
  /// in flight are queued first, so they are kept for the next launch.
  func dispose() {
    close()
    for immediate in immediateSends where immediate.generation == generation {
      queue.push(immediate.event)
    }
    immediateSends.removeAll()
    disposed = true
    completeDrains()
  }

  private func send() {
    guard !sending else { return }
    cancelTimer()
    sendNextBatch()
  }

  private func sendNextBatch() {
    guard let batch = queue.lock(maxCount: maxSize, maxBytes: Limits.maxBatchBytes) else {
      finishSending()
      return
    }
    sending = true
    let generation = self.generation
    transport.sendBatch(batch.events) { [self] result in
      scheduler.run { [self] in sent(batch, generation: generation, result) }
    }
  }

  private func sent(_ batch: EventQueue.Batch, generation: Int, _ result: BatchResult) {
    let failure = settle(result, events: batch.events.count)
    guard !disposed else { return }
    // Purged while in flight: there is nothing to put back or to back off for.
    guard generation == self.generation else {
      sendNextBatch()
      return
    }
    if let failure {
      queue.rollback(batch)
      retryLater(failure, events: batch.events.count)
      finishSending()
    } else {
      queue.commit(batch)
      if draining || queue.pendingCount >= maxSize {
        sendNextBatch()
      } else {
        finishSending()
      }
    }
  }

  private func sent(_ immediate: ImmediateSend, _ result: BatchResult) {
    let failure = settle(result, events: 1)
    guard !disposed else { return }
    immediateSends.removeAll { $0.id == immediate.id }
    if let failure, immediate.generation == generation {
      queue.push(immediate.event)
      retryLater(failure, events: 1)
    }
    completeDrainsIfSettled()
  }

  private func finishSending() {
    sending = false
    draining = false
    if queue.pendingCount > 0 {
      schedule(after: maxWaitMillis)
    }
    completeDrainsIfSettled()
  }

  /// Logs how a send went. Returns the failure when its events should be sent again.
  private func settle(_ result: BatchResult, events: Int) -> TransportError? {
    switch result {
    case .failure(let failure) where !failure.isPermanent:
      return failure
    case .failure(let failure):
      recovered()
      logger.error("\(eventCount(events)) dropped: rejected by the server (\(failure))", error: failure.underlying)
    case .success(let response):
      recovered()
      if let response, response.accepted < Int64(events) {
        warnPartiallyAccepted(response, sent: events)
      }
      logger.debug("Sent \(eventCount(events))")
    }
    return nil
  }

  private func warnPartiallyAccepted(_ response: BatchCreateResponse, sent: Int) {
    let reasons = response.droppedByReason.sortedByUTF16Key().map { "\($0.key): \($0.value)" }
    let detail = reasons.isEmpty ? "" : " (dropped: \(reasons.joined(separator: ", ")))"
    logger.warning("The server accepted \(response.accepted) of \(eventCount(sent))\(detail)")
  }

  private func retryLater(_ failure: TransportError, events: Int) {
    failures += 1
    cancelTimer()
    let reason = "Sending \(eventCount(events)) failed (\(failure))"
    guard !closed else {
      logger.warning("\(reason); kept in the queue", error: failure.underlying)
      return
    }
    let delay = retryDelayMillis()
    if failures == 1 {
      logger.warning(
        "\(reason); retrying in \(delay) ms. Until a send succeeds, failures are logged at debug level",
        error: failure.underlying
      )
    } else {
      logger.debug("\(reason); retrying in \(delay) ms")
    }
    schedule(after: delay)
  }

  // The server answered, so a retry timer waiting out a failing server has nothing left to wait for.
  private func recovered() {
    guard failures > 0 else { return }
    failures = 0
    if timer != nil {
      cancelTimer()
      schedule(after: maxWaitMillis)
    }
  }

  private func retryDelayMillis() -> Int64 {
    let base = max(maxWaitMillis, Self.retryFloorMillis)
    let cap = max(base, Self.retryCapMillis)
    var delay = base
    var doublings = failures - 1
    while doublings > 0, delay < cap {
      delay = delay > cap / 2 ? cap : delay * 2
      doublings -= 1
    }
    let jittered = (Double(delay) * (1 + Self.retryJitter * (2 * random() - 1))).rounded(.towardZero)
    return Int64(exactly: jittered) ?? delay
  }

  private func schedule(after delay: Int64) {
    guard !closed, timer == nil else { return }
    timer = scheduler.runAfter(milliseconds: delay) { [weak self] in
      guard let self else { return }
      timer = nil
      send()
    }
  }

  private func cancelTimer() {
    timer?.cancel()
    timer = nil
  }

  private func completeDrainsIfSettled() {
    if !sending, immediateSends.isEmpty {
      completeDrains()
    }
  }

  private func completeDrains() {
    guard !drainCompletions.isEmpty else { return }
    let completions = drainCompletions
    drainCompletions.removeAll()
    scheduler.run {
      for completion in completions {
        completion()
      }
    }
  }
}

/// "1 event", "2 events".
func eventCount(_ count: Int) -> String {
  count == 1 ? "1 event" : "\(count) events"
}
