import Foundation

struct UnsupportedValue: Error {
  let reason: String

  init(_ reason: String) {
    self.reason = reason
  }

  static let outOfRangeTime = UnsupportedValue("the time is outside the years 1 to 9999")
  static let outOfRangeDuration = UnsupportedValue("the duration is beyond ±10,000 years")
}

/// A host value as properties and traits read it. Nil for `nil`, `Optional.none` and `NSNull`.
enum HostValue {
  case text(String)
  case bool(Bool)
  case integer(Int64)
  case decimal(Double)
  // An integer too wide for int64 keeps its exact digits rather than rounding through a double.
  case digits(String)
  case date(Date)
  // A Swift Duration, as its components.
  case duration(seconds: Int64, attoseconds: Int64)
  case array([Any])
  // Unordered, so read in the order of the elements' JSON text.
  case set([Any])
  case object([AnyHashable: Any])
  case other(String)

  // Real NSNumbers are told apart by their dynamic type before any cast: Foundation casts the numbers
  // 0 and 1 to Bool, and a Swift Int or Double to NSNumber.
  init?(_ value: Any?) {
    guard let value = unwrapped(value), !(value is NSNull) else { return nil }
    if type(of: value) is NSNumber.Type, let number = value as? NSNumber {
      self.init(number: number)
    } else if let string = value as? String {
      self = .text(string)
    } else if let substring = value as? Substring {
      self = .text(String(substring))
    } else if let character = value as? Character {
      self = .text(String(character))
    } else if type(of: value) == Bool.self, let bool = value as? Bool {
      self = .bool(bool)
    } else if let integer = value as? any BinaryInteger {
      self = Int64(exactly: integer).map(HostValue.integer) ?? .digits(String(describing: integer))
    } else if let float = value as? any BinaryFloatingPoint {
      self = .decimal(decimalDouble(float))
    } else if let decimal = value as? Decimal {
      self = .decimal(Double(decimal.description) ?? .nan)
    } else if let raw = value as? any RawRepresentable, let text = raw.rawValue as? String {
      self = .text(text)
    } else if let date = value as? Date {
      self = .date(date)
    } else if #available(macOS 13, iOS 16, tvOS 16, watchOS 9, *), let duration = value as? Duration {
      self.init(duration: duration)
    } else if let object = value as? [AnyHashable: Any] {
      self = .object(object)
    } else if let set = value as? Set<AnyHashable> {
      self = .set(set.map(\.base))
    } else if let array = value as? [Any] {
      self = .array(array)
    } else {
      self = .other(String(describing: value))
    }
  }

  // Clamped first, since Duration.components traps past Int64 seconds. The bounds lie just beyond the range of
  // google.protobuf.Duration, so a clamped value still reads as out of range.
  @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
  private init(duration: Duration) {
    let bound = Limits.durationSeconds.upperBound + 1
    let (seconds, attoseconds) = min(max(duration, .seconds(-bound)), .seconds(bound)).components
    self = .duration(seconds: seconds, attoseconds: attoseconds)
  }

  // A boolean is a CFBoolean, on Linux too, whose objCType is the "c" of a char.
  private init(number: NSNumber) {
    if ObjectIdentifier(type(of: number)) == booleanNumberType {
      self = .bool(number.boolValue)
    } else if let decimal = number as? NSDecimalNumber {
      self = .decimal(Double(decimal.description) ?? decimal.doubleValue)
    } else {
      switch String(cString: number.objCType) {
      case "c", "s", "i", "l", "q":
        self = .integer(number.int64Value)
      case "C", "S", "I", "L", "Q":
        let unsigned = number.uint64Value
        self = Int64(exactly: unsigned).map(HostValue.integer) ?? .digits(String(unsigned))
      case "f":
        self = .decimal(decimalDouble(number.floatValue))
      default:
        self = .decimal(number.doubleValue)
      }
    }
  }
}

private let booleanNumberType = ObjectIdentifier(type(of: NSNumber(value: true)))

private protocol OptionalValue {
  var wrapped: Any? { get }
}

extension Optional: OptionalValue {
  fileprivate var wrapped: Any? {
    switch self {
    case .some(let value):
      return value
    case .none:
      return nil
    }
  }
}

// Optionals reach an Any boxed, nested ones too, and set elements and dictionary keys as AnyHashable.
private func unwrapped(_ value: Any?) -> Any? {
  var current = value
  while let value = current {
    if let optional = value as? any OptionalValue {
      current = optional.wrapped
    } else if type(of: value) == AnyHashable.self, let hashable = value as? AnyHashable {
      current = hashable.base
    } else {
      return value
    }
  }
  return nil
}

// A narrower float widens through its shortest decimal, so a Float 0.1 stays 0.1 rather than becoming
// 0.10000000149011612.
private func decimalDouble<Value: BinaryFloatingPoint>(_ value: Value) -> Double {
  if Value.significandBitCount < Double.significandBitCount, value.isFinite,
    let shortest = Double(String(describing: value))
  {
    return shortest
  }
  return Double(value)
}

/// Host values as JSON, for identify traits and for properties holding collections. Follows
/// `JSON.stringify` where it can: non-finite numbers become null and dates ISO 8601 strings. Integers
/// beyond ±(2^53 - 1) become strings, since a JSON number would round them. Durations become seconds,
/// as the server stores a duration property.
struct HostJSON {
  static let maxSafeInteger: Int64 = 9_007_199_254_740_991
  private static let maxDepth = 32
  // Bounds the work for a structure that holds itself.
  private static let maxValues = 10_000

  private var values = 0

  mutating func convert(_ value: HostValue?, depth: Int = 0) throws(UnsupportedValue) -> JSONValue {
    values += 1
    if values > Self.maxValues {
      throw UnsupportedValue("it holds more than \(Self.maxValues) values")
    }
    guard let value else { return .null }
    switch value {
    case .text(let text), .digits(let text), .other(let text):
      return .string(text)
    case .bool(let bool):
      return .bool(bool)
    case .integer(let integer):
      let safe = -Self.maxSafeInteger...Self.maxSafeInteger
      return safe.contains(integer) ? .number(Double(integer)) : .string(String(integer))
    case .decimal(let decimal):
      return decimal.isFinite ? .number(decimal) : .null
    case .date(let date):
      guard let millis = date.epochMillis, Limits.timestampMillis.contains(millis) else {
        throw .outOfRangeTime
      }
      return .string(iso8601(epochMillis: millis))
    case .duration(let seconds, let attoseconds):
      guard Limits.durationSeconds.contains(seconds) else { throw .outOfRangeDuration }
      return .number(Double(seconds) + Double(attoseconds) / 1e18)
    case .array(let elements):
      return .array(try convert(elements: elements, depth: depth))
    case .set(let elements):
      let converted = try convert(elements: elements, depth: depth).map { (text: $0.text, value: $0) }
      return .array(converted.sorted { $0.text.utf16.lexicographicallyPrecedes($1.text.utf16) }.map(\.value))
    case .object(let entries):
      try checkDepth(depth)
      var fields: [String: JSONValue] = [:]
      for (key, element) in sortedEntries(entries) {
        fields[key] = try convert(HostValue(element), depth: depth + 1)
      }
      return .object(fields)
    }
  }

  private mutating func convert(elements: [Any], depth: Int) throws(UnsupportedValue) -> [JSONValue] {
    try checkDepth(depth)
    var converted: [JSONValue] = []
    converted.reserveCapacity(elements.count)
    for element in elements {
      converted.append(try convert(HostValue(element), depth: depth + 1))
    }
    return converted
  }

  private func checkDepth(_ depth: Int) throws(UnsupportedValue) {
    if depth >= Self.maxDepth {
      throw UnsupportedValue("it is nested more than \(Self.maxDepth) levels deep")
    }
  }

  // Sorted so that two keys with one text, such as 1 and "1", resolve the same way every run.
  private func sortedEntries(_ entries: [AnyHashable: Any]) -> [(key: String, value: Any)] {
    entries.map { entry in
      let key = entry.key.base as? String ?? String(describing: entry.key.base)
      return (key: key, type: String(reflecting: type(of: entry.key.base)), value: entry.value)
    }
    .sorted { ($0.key, $0.type) < ($1.key, $1.type) }
    .map { (key: $0.key, value: $0.value) }
  }
}

extension JSONValue {
  /// The value as JSON text, object keys in UTF-16 order.
  var text: String {
    let writer = JSONWriter()
    write(to: writer)
    return writer.text
  }

  private func write(to writer: JSONWriter) {
    switch self {
    case .null:
      writer.nullValue()
    case .bool(let bool):
      writer.value(bool)
    case .string(let string):
      writer.value(string)
    case .number(let number):
      // A whole number reads as an integer, as JSON.stringify writes it.
      if abs(number) <= Double(HostJSON.maxSafeInteger), let whole = Int64(exactly: number) {
        writer.value(whole)
      } else {
        writer.value(number)
      }
    case .object(let fields):
      writer.beginObject()
      for (key, value) in fields.sortedByUTF16Key() {
        writer.name(key)
        value.write(to: writer)
      }
      writer.endObject()
    case .array(let elements):
      writer.beginArray()
      for element in elements {
        element.write(to: writer)
      }
      writer.endArray()
    }
  }
}
