/// A client's ops in call order. They wait until `start(with:)` gives them their context on the worker, then run there
/// one at a time; once the queue is closed, later ones are refused. Callable from any thread.
final class OpQueue<Context: Sendable>: Sendable {
  typealias Op = @Sendable (Context) -> Void

  private struct State: Sendable {
    var context: Context?
    var waiting: [Op] = []
    var isClosed = false
  }

  private let scheduler: any Scheduler
  private let state = Locked(State())

  init(scheduler: any Scheduler) {
    self.scheduler = scheduler
  }

  /// Queues `op`, or returns false once the queue is closed.
  func submit(_ op: @escaping Op) -> Bool {
    state.withLock { state in
      guard !state.isClosed else { return false }
      enqueue(op, in: &state)
      return true
    }
  }

  /// Queues `op` as the last op and refuses later ones. Returns false when the queue was closed already.
  @discardableResult
  func close(with op: @escaping Op) -> Bool {
    state.withLock { state in
      guard !state.isClosed else { return false }
      state.isClosed = true
      enqueue(op, in: &state)
      return true
    }
  }

  /// Runs the ops queued so far with `context`, and later ones as they come. Called once, on the worker.
  func start(with context: Context) {
    assert(scheduler.isOnWorker)
    let waiting = state.withLock { state in
      defer { state.waiting = [] }
      state.context = context
      return state.waiting
    }
    for op in waiting {
      op(context)
    }
  }

  // Scheduled under the lock, so that ops reach the worker in the order they were queued.
  private func enqueue(_ op: @escaping Op, in state: inout State) {
    guard let context = state.context else {
      state.waiting.append(op)
      return
    }
    scheduler.run { op(context) }
  }
}
