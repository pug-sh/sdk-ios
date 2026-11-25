import Testing

@testable import Pug

struct DurationsTests {
  private static let maxSeconds: Int64 = 315_576_000_000

  @Test("a duration is written in seconds with the fraction it needs")
  func formatsDurations() {
    let millis: [Int64] = [0, 1, 10, 1_500, 1_234, 61_000, -1, -1_500, .min]

    #expect(
      millis.map { durationText(milliseconds: $0) } == [
        "0s", "0.001s", "0.01s", "1.5s", "1.234s", "61s", "-0.001s", "-1.5s", "-9223372036854775.808s",
      ]
    )
  }

  @Test("a duration is rounded to the millisecond, and one that does not fit is nil")
  func roundsDurations() {
    #expect(durationMilliseconds(1.5) == 1_500)
    #expect(durationMilliseconds(1.2344) == 1_234)
    #expect(durationMilliseconds(1.2346) == 1_235)
    #expect(durationMilliseconds(-0.0) == 0)
    #expect(durationMilliseconds(.nan) == nil)
    #expect(durationMilliseconds(.infinity) == nil)
    #expect(durationMilliseconds(1e300) == nil)
  }

  @Test("seconds become a Duration rounded to the nanosecond, nanos taking the sign of the seconds")
  func durationFromSeconds() {
    let seconds: [Double] = [1.5, -1.5, 61, 0.25, 1.234_567_890_4, 0.999_999_999_6, -0.999_999_999_6, -0.0, 4e-10]

    #expect(
      seconds.map { PropertyValue.duration(seconds: $0) } == [
        .duration(seconds: 1, nanos: 500_000_000),
        .duration(seconds: -1, nanos: -500_000_000),
        .duration(seconds: 61, nanos: 0),
        .duration(seconds: 0, nanos: 250_000_000),
        .duration(seconds: 1, nanos: 234_567_890),
        .duration(seconds: 1, nanos: 0),
        .duration(seconds: -1, nanos: 0),
        .duration(seconds: 0, nanos: 0),
        .duration(seconds: 0, nanos: 0),
      ]
    )
  }

  @Test("seconds that are not finite or lie beyond a Duration's ten thousand years are nil")
  func durationFromUnusableSeconds() {
    let seconds: [Double] = [
      .nan, .infinity, -.infinity, 1e300, Double(Self.maxSeconds) + 1, -Double(Self.maxSeconds) - 1,
    ]

    #expect(seconds.allSatisfy { PropertyValue.duration(seconds: $0) == nil })
    #expect(PropertyValue.duration(seconds: Double(Self.maxSeconds)) == .duration(seconds: Self.maxSeconds, nanos: 0))
    #expect(
      PropertyValue.duration(seconds: -Double(Self.maxSeconds) - 0.5)
        == .duration(seconds: -Self.maxSeconds, nanos: -500_000_000)
    )
  }

  @Test("a Swift Duration's attoseconds round to the nearest nanosecond, halves away from zero")
  func durationFromComponents() {
    let components: [(seconds: Int64, attoseconds: Int64)] = [
      (1, 500_000_000_000_000_000),
      (0, 499_999_999),
      (0, 500_000_000),
      (0, -500_000_000),
      (0, 999_999_999_600_000_000),
      (2, -500_000_000_000_000_000),
      (-2, 500_000_000_000_000_000),
      (Self.maxSeconds, 999_999_999_000_000_000),
    ]

    #expect(
      components.map { PropertyValue.duration(seconds: $0.seconds, attoseconds: $0.attoseconds) } == [
        .duration(seconds: 1, nanos: 500_000_000),
        .duration(seconds: 0, nanos: 0),
        .duration(seconds: 0, nanos: 1),
        .duration(seconds: 0, nanos: -1),
        .duration(seconds: 1, nanos: 0),
        .duration(seconds: 1, nanos: 500_000_000),
        .duration(seconds: -1, nanos: -500_000_000),
        .duration(seconds: Self.maxSeconds, nanos: 999_999_999),
      ]
    )
  }

  @Test("seconds and nanos are normalized, and nil beyond a Duration's range")
  func normalizes() {
    #expect(PropertyValue.normalizedDuration(seconds: 1, nanos: -1) == .duration(seconds: 0, nanos: 999_999_999))
    #expect(PropertyValue.normalizedDuration(seconds: -1, nanos: 1) == .duration(seconds: 0, nanos: -999_999_999))
    #expect(PropertyValue.normalizedDuration(seconds: 0, nanos: 1_000_000_000) == .duration(seconds: 1, nanos: 0))
    #expect(PropertyValue.normalizedDuration(seconds: 0, nanos: -1_000_000_000) == .duration(seconds: -1, nanos: 0))
    #expect(
      PropertyValue.normalizedDuration(seconds: Self.maxSeconds + 1, nanos: -1)
        == .duration(seconds: Self.maxSeconds, nanos: 999_999_999))
    #expect(PropertyValue.normalizedDuration(seconds: Self.maxSeconds + 1, nanos: 0) == nil)
    #expect(PropertyValue.normalizedDuration(seconds: Self.maxSeconds, nanos: 1_000_000_000) == nil)
    #expect(PropertyValue.normalizedDuration(seconds: -Self.maxSeconds - 1, nanos: 0) == nil)
    #expect(PropertyValue.normalizedDuration(seconds: 0, nanos: 1_000_000_001) == nil)
    #expect(PropertyValue.normalizedDuration(seconds: .max, nanos: 0) == nil)
    #expect(PropertyValue.normalizedDuration(seconds: .min, nanos: .min) == nil)
  }

  @Test("seconds at the Int64 bounds are refused before nanos are carried into them")
  func normalizesWithoutOverflow() {
    #expect(PropertyValue.normalizedDuration(seconds: .max, nanos: 1_000_000_000) == nil)
    #expect(PropertyValue.normalizedDuration(seconds: .min, nanos: -1_000_000_000) == nil)
    #expect(PropertyValue.normalizedDuration(seconds: .max, nanos: -1_000_000_000) == nil)
    #expect(PropertyValue.normalizedDuration(seconds: .min, nanos: 1_000_000_000) == nil)
  }
}
