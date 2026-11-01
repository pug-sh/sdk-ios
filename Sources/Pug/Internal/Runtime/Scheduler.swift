import Dispatch

protocol Cancellable: Sendable {
  func cancel()
}

/// The worker the SDK's state lives on, and the clock its calls are dated by. `DispatchScheduler` is
/// the real one; tests run virtual time on their own thread.
protocol Scheduler: Clock {
  /// Whether the calling code runs on the worker, for assertions.
  var isOnWorker: Bool { get }

  /// Runs `work` on the worker, after the work already scheduled.
  func run(_ work: @escaping @Sendable () -> Void)

  func runAfter(milliseconds: Int64, _ work: @escaping @Sendable () -> Void) -> any Cancellable
}

/// Work that runs at most once, unless cancelled first. Cancelling releases it at once rather than
/// when it falls due, so a cancelled timer does not keep what it captured alive until then.
final class PendingWork: Cancellable {
  private let work: Locked<(@Sendable () -> Void)?>

  init(_ work: @escaping @Sendable () -> Void) {
    self.work = Locked(work)
  }

  var isPending: Bool {
    work.withLock { $0 != nil }
  }

  func cancel() {
    work.withLock { $0 = nil }
  }

  func run() {
    let work = self.work.withLock { work in
      defer { work = nil }
      return work
    }
    work?()
  }
}

// One serial DispatchQueue, which every client shares. Unchecked because not every SDK marks
// DispatchSpecificKey Sendable; the class is immutable, and the queue and the key are thread-safe.
final class DispatchScheduler: Scheduler, @unchecked Sendable {
  // Dispatch takes Int milliseconds; capped there, the conversion and the nanoseconds it becomes
  // stay in range on every platform. The SDK's longest delay is minutes.
  private static let maxDelayMillis = Int64(Int32.max)

  private let queue: DispatchQueue
  private let key = DispatchSpecificKey<Bool>()

  init(label: String = "sh.pug.worker") {
    queue = DispatchQueue(label: label, qos: .utility)
    queue.setSpecific(key: key, value: true)
  }

  var nowMillis: Int64 {
    SystemClock().nowMillis
  }

  var isOnWorker: Bool {
    DispatchQueue.getSpecific(key: key) ?? false
  }

  func run(_ work: @escaping @Sendable () -> Void) {
    queue.async(execute: work)
  }

  func runAfter(milliseconds: Int64, _ work: @escaping @Sendable () -> Void) -> any Cancellable {
    let pending = PendingWork(work)
    let delay = Int(clamping: min(max(milliseconds, 0), Self.maxDelayMillis))
    queue.asyncAfter(deadline: .now() + .milliseconds(delay)) { pending.run() }
    return pending
  }
}
