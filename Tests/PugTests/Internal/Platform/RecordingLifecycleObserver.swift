@testable import Pug

/// What a platform reported to the client.
enum Reported: Equatable, Sendable {
  case foreground
  case background
  case screen(String, returning: Bool)
  case screenLeft
}

final class RecordingLifecycleObserver: LifecycleObserver {
  private let recorded = Locked<[Reported]>([])
  private let settles = Locked<[@Sendable () -> Void]>([])

  var reported: [Reported] {
    recorded.withLock { $0 }
  }

  func appDidEnterForeground() {
    recorded.withLock { $0.append(.foreground) }
  }

  func appDidEnterBackground(then settled: @escaping @Sendable () -> Void) {
    recorded.withLock { $0.append(.background) }
    settles.withLock { $0.append(settled) }
  }

  func screenDidAppear(name: String, screenClass: String?, isReturning: Bool) {
    recorded.withLock { $0.append(.screen(name, returning: isReturning)) }
  }

  func screenDidDisappear() {
    recorded.withLock { $0.append(.screenLeft) }
  }

  /// Settles what leaving the foreground sent.
  func settle() {
    let settles = settles.withLock { settles in
      defer { settles = [] }
      return settles
    }
    for settled in settles {
      settled()
    }
  }
}
