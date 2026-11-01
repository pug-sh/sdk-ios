@testable import Pug

/// Virtual time for tests, after kotlinx-coroutines-test's `TestCoroutineScheduler`: work runs only
/// when the test calls `runCurrent()`, `advanceTime(by:)` or `advanceUntilIdle()`, on the test's
/// thread, in order of due time and then of scheduling.
final class TestScheduler: Scheduler {
  private struct Entry: Sendable {
    let due: Int64
    let work: PendingWork
  }

  private struct State: Sendable {
    var now: Int64 = 0
    // By due time, and at one time in the order scheduled.
    var entries: [Entry] = []
  }

  let startMillis: Int64
  private let state = Locked(State())

  init(startMillis: Int64 = 1_760_000_000_000) {
    self.startMillis = startMillis
  }

  /// Virtual milliseconds since the scheduler was created.
  var currentTime: Int64 {
    state.withLock { $0.now }
  }

  var nowMillis: Int64 {
    startMillis + currentTime
  }

  // Everything a test does runs on its own thread, which stands in for the worker.
  var isOnWorker: Bool {
    true
  }

  func run(_ work: @escaping @Sendable () -> Void) {
    _ = enqueue(work, after: 0)
  }

  func runAfter(milliseconds: Int64, _ work: @escaping @Sendable () -> Void) -> any Cancellable {
    enqueue(work, after: milliseconds)
  }

  /// Runs the work due now, including what that work schedules for now.
  func runCurrent() {
    let now = currentTime
    while let work = takeNext(dueBy: now) {
      work.run()
    }
  }

  /// Moves time forward by `milliseconds`, running the work due before then but not at then: as
  /// in kotlinx-coroutines-test, `runCurrent()` runs that.
  func advanceTime(by milliseconds: Int64) {
    let target = currentTime + milliseconds
    while let work = takeNext(dueBy: target - 1) {
      work.run()
    }
    state.withLock { $0.now = max($0.now, target) }
  }

  /// Runs everything scheduled, moving time forward to each piece of work as it falls due.
  func advanceUntilIdle() {
    while let work = takeNext(dueBy: .max) {
      work.run()
    }
  }

  private func enqueue(_ work: @escaping @Sendable () -> Void, after milliseconds: Int64) -> PendingWork {
    let pending = PendingWork(work)
    state.withLock { state in
      let due = state.now + max(milliseconds, 0)
      let index = state.entries.firstIndex { $0.due > due } ?? state.entries.endIndex
      state.entries.insert(Entry(due: due, work: pending), at: index)
    }
    return pending
  }

  // Cancelled work is dropped rather than run as a no-op, so it does not move time forward.
  private func takeNext(dueBy limit: Int64) -> PendingWork? {
    state.withLock { state in
      state.entries.removeAll { !$0.work.isPending }
      guard let next = state.entries.first, next.due <= limit else { return nil }
      state.entries.removeFirst()
      state.now = max(state.now, next.due)
      return next.work
    }
  }
}
