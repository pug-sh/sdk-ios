import Foundation

/// A duration as text, in seconds with a trailing `s`: `"1.5s"`.
func durationText(milliseconds: Int64) -> String {
  let sign = milliseconds < 0 ? "-" : ""
  let (seconds, fraction) = milliseconds.quotientAndRemainder(dividingBy: 1_000)
  if fraction == 0 {
    return "\(sign)\(seconds.magnitude)s"
  }
  var digits = String(fraction.magnitude)
  digits = String(repeating: "0", count: max(3 - digits.count, 0)) + digits
  while digits.hasSuffix("0") {
    digits.removeLast()
  }
  return "\(sign)\(seconds.magnitude).\(digits)s"
}

/// `seconds` rounded to the millisecond, or nil when it is not finite or does not fit.
func durationMilliseconds(_ seconds: TimeInterval) -> Int64? {
  Int64(exactly: (seconds * 1_000).rounded())
}

extension PropertyValue {
  private static let nanosPerSecond: Int64 = 1_000_000_000

  /// `seconds` rounded to the nanosecond, or nil when it is not finite or lies beyond a Duration's range.
  static func duration(seconds: TimeInterval) -> PropertyValue? {
    let whole = seconds.rounded(.towardZero)
    guard let wholeSeconds = Int64(exactly: whole),
      let nanos = Int64(exactly: ((seconds - whole) * 1e9).rounded())
    else { return nil }
    return normalizedDuration(seconds: wholeSeconds, nanos: nanos)
  }

  /// A Swift `Duration`'s components rounded to the nanosecond, or nil beyond a Duration's range.
  static func duration(seconds: Int64, attoseconds: Int64) -> PropertyValue? {
    let (nanos, remainder) = attoseconds.quotientAndRemainder(dividingBy: 1_000_000_000)
    let rounded = nanos + (remainder.magnitude < 500_000_000 ? 0 : remainder.signum())
    return normalizedDuration(seconds: seconds, nanos: rounded)
  }

  /// `seconds` and up to a second of `nanos`, of either sign, normalized; nil beyond a Duration's range.
  static func normalizedDuration(seconds: Int64, nanos: Int64) -> PropertyValue? {
    let range = Limits.durationSeconds
    // A second of slack, which nanos of the other sign can take back, keeps the arithmetic below from overflowing.
    guard nanos.magnitude <= 1_000_000_000, (range.lowerBound - 1...range.upperBound + 1).contains(seconds) else {
      return nil
    }
    var seconds = seconds + nanos / nanosPerSecond
    var nanos = nanos % nanosPerSecond
    if seconds > 0, nanos < 0 {
      seconds -= 1
      nanos += nanosPerSecond
    } else if seconds < 0, nanos > 0 {
      seconds += 1
      nanos -= nanosPerSecond
    }
    guard range.contains(seconds), let nanos = Int32(exactly: nanos) else { return nil }
    return .duration(seconds: seconds, nanos: nanos)
  }
}
