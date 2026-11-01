import Foundation

/// A value that callers' threads share with the worker, behind a lock. `NSLock` rather than
/// `Mutex`, which needs iOS 18.
final class Locked<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value

  init(_ value: Value) {
    self.value = value
  }

  func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body(&value)
  }
}
