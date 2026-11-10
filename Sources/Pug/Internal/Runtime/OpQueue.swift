/// A client's ops in call order. They wait until `start(with:)` gives them their context on the worker, then run there
/// one at a time; once the queue is closed, later ones are refused. Callable from any thread.
final class OpQueue<Context: Sendable>: Sendable {
  typealias Op = @Sendable (Context) -> Void

  private struct Waiting: Sendable {
    let op: Op
    let isDroppable: Bool
  }

  private struct State: Sendable {
    var context: Context?
    var waiting: [Waiting] = []
    var droppable = 0
    var dropped = 0
    var isClosed = false
  }

  private let scheduler: any Scheduler
  private let maxDroppable: Int
  private let state = Locked(State())

  /// Of the droppable ops waiting for the context, which may take hours, the oldest beyond `maxDroppable` are dropped.
  init(scheduler: any Scheduler, maxDroppable: Int = .max) {
    self.scheduler = scheduler
    self.maxDroppable = maxDroppable
  }

  /// Queues `op`, or returns false once the queue is closed.
  func submit(_ op: @escaping Op, isDroppable: Bool = false) -> Bool {
    state.withLock { state in
      guard !state.isClosed else { return false }
      enqueue(Waiting(op: op, isDroppable: isDroppable), in: &state)
      return true
    }
  }

  /// Queues `op` as the last op and refuses later ones. Returns false when the queue was closed already.
  @discardableResult
  func close(with op: @escaping Op) -> Bool {
    state.withLock { state in
      guard !state.isClosed else { return false }
      state.isClosed = true
      enqueue(Waiting(op: op, isDroppable: false), in: &state)
      return true
    }
  }

  /// Runs the ops queued so far with `context`, and later ones as they come, and returns how many droppable ones were
  /// dropped while waiting. Called once, on the worker.
  @discardableResult
  func start(with context: Context) -> Int {
    assert(scheduler.isOnWorker)
    let (waiting, dropped) = state.withLock { state in
      defer { state.waiting = [] }
      state.context = context
      return (state.waiting, state.dropped)
    }
    for waiting in waiting {
      waiting.op(context)
    }
    return dropped
  }

  // Scheduled under the lock, so that ops reach the worker in the order they were queued.
  private func enqueue(_ waiting: Waiting, in state: inout State) {
    guard let context = state.context else {
      state.waiting.append(waiting)
      if waiting.isDroppable {
        state.droppable += 1
      }
      if state.droppable > maxDroppable, let oldest = state.waiting.firstIndex(where: \.isDroppable) {
        state.waiting.remove(at: oldest)
        state.droppable -= 1
        state.dropped += 1
      }
      return
    }
    scheduler.run { waiting.op(context) }
  }
}
