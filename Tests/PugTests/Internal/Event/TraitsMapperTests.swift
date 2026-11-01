import Foundation
import Testing

@testable import Pug

struct TraitsMapperTests {
  private struct Point {
    let x: Int
    let y: Int
  }

  private let logger = RecordingLogger()
  private var mapper: TraitsMapper {
    TraitsMapper(logger: logger.safe())
  }

  @Test("nested dictionaries and arrays are kept as Struct values")
  func nesting() {
    let mapped = mapper.map([
      "plan": "pro",
      "seats": 3,
      "score": Float(0.5),
      "active": true,
      "address": ["city": "Z\u{FC}rich", "zip": 8_001] as [String: Any],
      "tags": ["a", NSNull(), [Int64(1)], [String: Int]()] as [Any],
      "flags": NSArray(array: [NSNumber(value: true)]),
    ])

    let expected: [String: JSONValue] = [
      "plan": .string("pro"),
      "seats": .number(3),
      "score": .number(0.5),
      "active": .bool(true),
      "address": .object(["city": .string("Z\u{FC}rich"), "zip": .number(8_001)]),
      "tags": .array([.string("a"), .null, .array([.number(1)]), .object([:])]),
      "flags": .array([.bool(true)]),
    ]
    #expect(mapped == expected)
    #expect(logger.entries.isEmpty)
  }

  @Test("a nil trait is sent as null")
  func nilTraits() {
    let none: String? = nil

    #expect(mapper.map(["deleted": NSNull(), "gone": none as Any]) == ["deleted": .null, "gone": .null])
    #expect(logger.entries.isEmpty)
  }

  @Test("integers a double cannot hold exactly become strings")
  func wideIntegers() {
    let mapped = mapper.map([
      "safe": 9_007_199_254_740_991,
      "unsafe": 9_007_199_254_740_993,
      "wide": UInt64.max,
    ])

    let expected: [String: JSONValue] = [
      "safe": .number(9_007_199_254_740_991),
      "unsafe": .string("9007199254740993"),
      "wide": .string("18446744073709551615"),
    ]
    #expect(mapped == expected)
  }

  @Test("dates become ISO 8601 strings")
  func dates() {
    let mapped = mapper.map([
      "signedUp": Date(timeIntervalSince1970: 0),
      "lastSeen": NSDate(timeIntervalSince1970: 1.5),
    ])

    #expect(
      mapped == [
        "signedUp": .string("1970-01-01T00:00:00.000Z"), "lastSeen": .string("1970-01-01T00:00:01.500Z"),
      ]
    )
  }

  @Test("the first and last representable days use the proleptic Gregorian calendar")
  func calendarBounds() {
    let first = Double(Limits.timestampMillis.lowerBound) / 1_000
    let last = Double(Limits.timestampMillis.upperBound) / 1_000

    let mapped = mapper.map([
      "first": Date(timeIntervalSince1970: first),
      "last": Date(timeIntervalSince1970: last),
      "after": Date(timeIntervalSince1970: last + 0.001),
    ])

    #expect(
      mapped == ["first": .string("0001-01-01T00:00:00.000Z"), "last": .string("9999-12-31T23:59:59.999Z")]
    )
    #expect(logger.warnings == ["Trait \"after\" was dropped: the time is outside the years 1 to 9999"])
  }

  @Test("a non-finite number is dropped at the top level and null when nested")
  func nonFinite() {
    let mapped = mapper.map(["nan": Double.nan, "nested": [Double.infinity]])

    #expect(mapped == ["nested": .array([.null])])
    #expect(logger.warnings == ["Trait \"nan\" was dropped: it is not a finite number"])
  }

  @Test("strings are not truncated")
  func longStrings() {
    let long = String(repeating: "x", count: 5_000)

    #expect(mapper.map(["bio": long]) == ["bio": .string(long)])
  }

  @Test("values of other types are sent as their text")
  func otherTypes() throws {
    let id = try #require(UUID(uuidString: "0190A5B4-7C2E-7A3B-8F00-0123456789AB"))

    let mapped = mapper.map(["id": id, "point": Point(x: 1, y: 2), "nested": ["ids": [id]]])

    let expected: [String: JSONValue] = [
      "id": .string("0190A5B4-7C2E-7A3B-8F00-0123456789AB"),
      "point": .string("Point(x: 1, y: 2)"),
      "nested": .object(["ids": .array([.string("0190A5B4-7C2E-7A3B-8F00-0123456789AB")])]),
    ]
    #expect(mapped == expected)
    #expect(logger.entries.isEmpty)
  }

  @Test("a trait nested too deeply is dropped alone")
  func deepTraits() {
    var deep: Any = 1
    for _ in 0..<40 {
      deep = ["level": deep]
    }

    let mapped = mapper.map(["deep": deep, "kept": 1])

    #expect(mapped == ["kept": .number(1)])
    #expect(logger.warnings == ["Trait \"deep\" was dropped: it is nested more than 32 levels deep"])
  }
}
