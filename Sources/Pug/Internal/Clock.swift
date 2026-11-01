import Foundation

protocol Clock: Sendable {
  /// Wall-clock milliseconds since 1970.
  var nowMillis: Int64 { get }
}

struct SystemClock: Clock {
  var nowMillis: Int64 {
    Int64(exactly: (Date().timeIntervalSince1970 * 1_000).rounded(.down)) ?? 0
  }
}
