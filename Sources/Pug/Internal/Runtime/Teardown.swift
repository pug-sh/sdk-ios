/// Finishes once a destroyed client no longer touches storage, which the next client waits for.
final class Teardown: Sendable {
  private struct State: Sendable {
    var isFinished = false
    var waiters: [@Sendable () -> Void] = []
  }

  private let state = Locked(State())

  var isFinished: Bool {
    state.withLock { $0.isFinished }
  }

  /// Runs `work` once finished: at once if it is, else on the thread that finishes it.
  func whenFinished(_ work: @escaping @Sendable () -> Void) {
    let isFinished = state.withLock { state in
      if !state.isFinished {
        state.waiters.append(work)
      }
      return state.isFinished
    }
    if isFinished {
      work()
    }
  }

  func finish() {
    let waiters = state.withLock { state in
      defer { state.waiters = [] }
      state.isFinished = true
      return state.waiters
    }
    for waiter in waiters {
      waiter()
    }
  }
}
