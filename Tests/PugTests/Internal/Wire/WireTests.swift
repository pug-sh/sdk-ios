import Foundation
import SwiftProtobuf
import Testing

@testable import Pug

struct WireTests {
  @Test("a batch with every property value type matches swift-protobuf byte for byte")
  func batchMatchesReference() throws {
    let events = [fullEvent(), minimalEvent()]

    let encoded = Wire.encodeBatchCreateRequest(events)

    let reference = ReferenceMessages.batch(events)
    #expect(try encoded == reference.deterministicBytes())
    #expect(try Sdk_Events_V1_BatchCreateRequest(serializedBytes: encoded) == reference)
  }

  @Test("map keys are written in UTF-16 order where Swift's own order differs")
  func utf16KeyOrder() throws {
    var event = minimalEvent()
    event.customProperties = [
      "\u{FF5E}": .int(1), "\u{1F30D}": .int(2), "e\u{301}x": .int(3), "\u{E9}a": .int(4), "z": .int(5),
    ]

    let encoded = Wire.encodeBatchCreateRequest([event])

    #expect(try mapKeys(in: encoded) == ["e\u{301}x", "z", "\u{E9}a", "\u{1F30D}", "\u{FF5E}"])
    #expect(try Sdk_Events_V1_BatchCreateRequest(serializedBytes: encoded) == ReferenceMessages.batch([event]))
    #expect(try encoded != ReferenceMessages.batch([event]).deterministicBytes())
  }

  @Test("random events with ASCII keys match swift-protobuf byte for byte")
  func randomEventsMatchReference() throws {
    var fixtures = Fixtures(seed: 0x5EED)

    for _ in 0..<200 {
      let events = (0..<fixtures.count(0...3)).map { _ in fixtures.event(keys: .ascii) }

      let encoded = Wire.encodeBatchCreateRequest(events)

      #expect(try encoded == ReferenceMessages.batch(events).deterministicBytes())
    }
  }

  @Test("random events with any keys decode equal in swift-protobuf, keys in UTF-16 order")
  func randomEventsDecodeEqual() throws {
    var fixtures = Fixtures(seed: 0xC0DE)

    for _ in 0..<200 {
      let event = fixtures.event(keys: .unicode)

      let encoded = Wire.encodeBatchCreateRequest([event])

      #expect(try Sdk_Events_V1_BatchCreateRequest(serializedBytes: encoded) == ReferenceMessages.batch([event]))
      let keys = try mapKeys(in: encoded)
      let auto = keys.prefix(event.autoProperties.count)
      let custom = keys.dropFirst(event.autoProperties.count)
      #expect(auto.elementsEqual(auto.sorted(by: utf16Precedes)))
      #expect(custom.elementsEqual(custom.sorted(by: utf16Precedes)))
    }
  }

  @Test("oneof members holding default values are still written")
  func oneofDefaults() throws {
    var event = minimalEvent()
    event.customProperties = [
      "zero": .int(0), "zeroDouble": .double(0), "false": .bool(false), "empty": .string(""),
      "epoch": .timestamp(epochMillis: 0),
    ]

    let parsed = try Sdk_Events_V1_BatchCreateRequest(serializedBytes: Wire.encodeBatchCreateRequest([event]))

    let properties = try #require(parsed.events.first).customProperties
    #expect(properties.count == 5)
    for (key, value) in properties {
      #expect(value.value != nil, "PropertyValue for \(key) has no oneof member set")
    }
  }

  @Test("empty ids are left out, not sent as set fields")
  func emptyIds() throws {
    var event = minimalEvent()
    event.eventId = ""
    event.distinctId = ""
    event.sessionId = ""
    event.kind = ""

    let parsed = try Sdk_Events_V1_BatchCreateRequest(serializedBytes: Wire.encodeBatchCreateRequest([event]))

    let decoded = try #require(parsed.events.first)
    #expect(!decoded.hasEventID && !decoded.hasDistinctID && !decoded.hasSessionID && !decoded.hasKind)
    #expect(decoded.hasOccurTime)
  }

  @Test("an empty batch encodes to an empty message")
  func emptyBatch() {
    #expect(Wire.encodeBatchCreateRequest([]).isEmpty)
  }

  @Test("event sizes add up to the encoded batch")
  func eventSizes() {
    var empty = minimalEvent()
    empty.eventId = ""
    empty.distinctId = ""
    empty.sessionId = ""
    empty.kind = ""
    var odd = minimalEvent()
    odd.occurTimeMillis = -1
    odd.customProperties = [
      "lone \u{FFFD}": .string("\u{FFFD} ends \u{1F30D}"),
      "long": .string(String(repeating: "x", count: 200)),
      "longer": .string(String(repeating: "y", count: 20_000)),
      "wholeSecond": .timestamp(epochMillis: -1_000),
      "epoch": .timestamp(epochMillis: 0),
      "negative": .int(-1),
      "extremes": .timestamp(epochMillis: .min),
    ]
    var fixtures = Fixtures(seed: 0x512E)
    let events =
      [fullEvent(), minimalEvent(), empty, odd]
      + (0..<100).map { _ in fixtures.event(keys: .unicode, emptyIds: true) }

    for event in events {
      #expect(Wire.eventSize(event) == Wire.encodeBatchCreateRequest([event]).count, "\(event.kind)")
    }
    #expect(Wire.encodeBatchCreateRequest(events).count == events.map(Wire.eventSize).reduce(0, +))
  }

  @Test("identify with nested traits matches swift-protobuf byte for byte")
  func identifyMatchesReference() throws {
    let request = IdentifyRequest(
      externalId: "user-42",
      traits: [
        "plan": .string("pro"),
        "seats": .number(3),
        "score": .number(-0.5),
        "active": .bool(true),
        "trial": .bool(false),
        "deleted": .null,
        "address": .object(["city": .string("Z\u{FC}rich"), "zip": .number(8_001)]),
        "tags": .array([.string("a"), .number(0), .null, .bool(false), .array([]), .object([:])]),
      ],
      anonymousId: "anon-0192f3a4-1b2c-7d3e-8f40-5a6b7c8d9e0f"
    )

    let encoded = Wire.encodeIdentifyRequest(request)

    let reference = ReferenceMessages.identify(request)
    #expect(try encoded == reference.deterministicBytes())
    #expect(try Sdk_Profiles_V1_IdentifyRequest(serializedBytes: encoded) == reference)
  }

  @Test("identify leaves out traits and the anonymous id when absent")
  func identifyOmissions() throws {
    for anonymousId in [nil, ""] {
      let request = IdentifyRequest(externalId: "user-42", traits: [:], anonymousId: anonymousId)

      let encoded = Wire.encodeIdentifyRequest(request)

      let reference = ReferenceMessages.identify(IdentifyRequest(externalId: "user-42", traits: [:]))
      #expect(try encoded == reference.deterministicBytes())
      let parsed = try Sdk_Profiles_V1_IdentifyRequest(serializedBytes: encoded)
      #expect(parsed.hasExternalID && !parsed.hasTraits && !parsed.hasAnonymousID && !parsed.hasDeviceID)
    }
  }

  @Test("decodes a batch response and skips unknown fields")
  func decodesResponse() throws {
    let reference = ReferenceMessages.batchResponse(
      accepted: 7,
      dropped: 3,
      droppedByReason: ["salt_unavailable": 2, "day_out_of_range": 1]
    )
    // Field 99 as a varint, 100 length-delimited, and 101 as fixed32 then fixed64.
    let unknown: [UInt8] =
      [0x98, 0x06, 0x05] + [0xA2, 0x06, 0x06] + Array("future".utf8) + [0xAD, 0x06, 0x07, 0x00, 0x00, 0x00]
      + [0xA9, 0x06, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
    let bytes = try reference.deterministicBytes() + unknown
    #expect(try Sdk_Events_V1_BatchCreateResponse(serializedBytes: bytes).unknownFields.data == Data(unknown))

    let decoded = try Wire.decodeBatchCreateResponse(bytes)

    #expect(
      decoded
        == BatchCreateResponse(accepted: 7, droppedByReason: ["salt_unavailable": 2, "day_out_of_range": 1]))
  }

  @Test("unknown fields inside a reason entry are skipped")
  func unknownEntryFields() throws {
    // Entry: reason "x", an unknown field 7, count 4.
    let entry: [UInt8] = [0x0A, 0x01, UInt8(ascii: "x"), 0x38, 0x01, 0x10, 0x04]

    let decoded = try Wire.decodeBatchCreateResponse([0x1A, UInt8(entry.count)] + entry)

    #expect(decoded == BatchCreateResponse(accepted: 0, droppedByReason: ["x": 4]))
  }

  @Test("decodes uint32 counts above Int32.max")
  func largeCounts() throws {
    let response = ReferenceMessages.batchResponse(accepted: .max, dropped: 0, droppedByReason: [:])

    #expect(try Wire.decodeBatchCreateResponse(response.deterministicBytes()).accepted == 4_294_967_295)
  }

  @Test("a count wider than 32 bits is truncated, as swift-protobuf reads it")
  func wideCounts() throws {
    // accepted = 2^32 + 5.
    let bytes: [UInt8] = [0x08, 0x85, 0x80, 0x80, 0x80, 0x10]

    #expect(try Wire.decodeBatchCreateResponse(bytes).accepted == 5)
    #expect(try Sdk_Events_V1_BatchCreateResponse(serializedBytes: bytes).accepted == 5)
  }

  @Test("a repeated reason keeps its last count, as swift-protobuf reads it")
  func repeatedReason() throws {
    let entry: (UInt8) -> [UInt8] = { [0x1A, 0x05, 0x0A, 0x01, UInt8(ascii: "r"), 0x10, $0] }
    let bytes = entry(1) + entry(2)

    #expect(try Wire.decodeBatchCreateResponse(bytes).droppedByReason == ["r": 2])
    #expect(try Sdk_Events_V1_BatchCreateResponse(serializedBytes: bytes).droppedByReason == ["r": 2])
  }

  @Test("random responses decode as swift-protobuf encodes them")
  func randomResponses() throws {
    var fixtures = Fixtures(seed: 0xD20B)

    for _ in 0..<200 {
      var reasons: [String: UInt32] = [:]
      for _ in 0..<fixtures.count(0...4) {
        reasons[fixtures.string(.unicode)] = fixtures.uint32()
      }
      let response = ReferenceMessages.batchResponse(
        accepted: fixtures.uint32(),
        dropped: fixtures.uint32(),
        droppedByReason: reasons
      )

      let decoded = try Wire.decodeBatchCreateResponse(response.serializedBytes())

      #expect(decoded.accepted == Int64(response.accepted))
      #expect(decoded.droppedByReason == reasons.mapValues { Int64($0) })
    }
  }

  @Test("an empty body decodes as nothing accepted")
  func emptyResponse() throws {
    #expect(try Wire.decodeBatchCreateResponse([]) == BatchCreateResponse(accepted: 0, droppedByReason: [:]))
  }

  @Test("malformed responses fail to decode")
  func malformedResponses() throws {
    let valid = try ReferenceMessages.batchResponse(
      accepted: 1, dropped: 1, droppedByReason: ["salt_unavailable": 1]
    )
    .deterministicBytes()

    for bytes in [Array(valid.dropLast()), [0x08], [0x1A, 0x7F], [0x0B], [0x1A, 0x02, 0x0A, 0x05]] {
      #expect(throws: ProtoDecodeError.self, "\(bytes)") { try Wire.decodeBatchCreateResponse(bytes) }
    }
  }

  // What the server, a proxy or a captive portal sends back must never trap: decoding either
  // succeeds or throws.
  @Test("hostile responses decode or throw, and never trap")
  func hostileResponses() throws {
    let valid = try ReferenceMessages.batchResponse(
      accepted: 7,
      dropped: 3,
      droppedByReason: ["salt_unavailable": 2, "day_out_of_range": 1]
    ).deterministicBytes()
    var inputs = (0..<valid.count).map { Array(valid.prefix($0)) }
    for index in valid.indices {
      for byte: UInt8 in [0x00, 0x01, 0x07, 0x7F, 0x80, 0xFF] {
        var mutated = valid
        mutated[index] = byte
        inputs.append(mutated)
      }
    }
    var fixtures = Fixtures(seed: 0xBAD)
    for _ in 0..<5_000 {
      inputs.append(fixtures.bytes(count: 0...48))
    }

    for input in inputs {
      _ = try? Wire.decodeBatchCreateResponse(input)
    }
  }

  private func fullEvent() -> Event {
    Event(
      eventId: "0192f3a4-1b2c-7d3e-8f40-5a6b7c8d9e0f",
      kind: "add_to_cart",
      distinctId: "anon-0192f3a4-0000-7000-8000-000000000001",
      sessionId: "0192f3a4-0000-7000-8000-000000000002",
      occurTimeMillis: 1_760_000_000_123,
      autoProperties: [
        "$platform": .string("ios"),
        "$screenWidth": .int(402),
        "$screenScale": .double(3),
        "$mobile": .bool(true),
      ],
      customProperties: [
        "productId": .string("sku-1"),
        "name": .string("h\u{E9}llo w\u{F6}rld \u{1F30D} \u{65E5}\u{672C}"),
        "quantity": .int(3),
        "negative": .int(-42),
        "min": .int(.min),
        "max": .int(.max),
        "price": .double(19.99),
        "negativeZero": .double(-0.0),
        "tiny": .double(.leastNonzeroMagnitude),
        "gift": .bool(false),
        "addedAt": .timestamp(epochMillis: 1_760_000_000_999),
        "before1970": .timestamp(epochMillis: -1),
        "wholeSecond": .timestamp(epochMillis: 1_000),
        "\u{FC}-key": .string("unicode key"),
        "Z-upper": .string("sorts before lowercase"),
      ]
    )
  }

  private func minimalEvent() -> Event {
    Event(
      eventId: "0192f3a4-1b2c-7d3e-8f40-000000000000",
      kind: "app_open",
      distinctId: "user-42",
      sessionId: "0192f3a4-0000-7000-8000-000000000003",
      occurTimeMillis: 0,
      autoProperties: [:],
      customProperties: [:]
    )
  }

  /// The keys of every map entry in an encoded batch, in the order they were written.
  private func mapKeys(in batch: [UInt8]) throws -> [String] {
    var keys: [String] = []
    var request = ProtoReader(batch)
    while !request.isAtEnd {
      _ = try request.readTag()
      var event = try request.readMessage()
      while !event.isAtEnd {
        let tag = try event.readTag()
        guard tag == 2 << 3 | WireType.len.rawValue || tag == 3 << 3 | WireType.len.rawValue else {
          try event.skip(wireType: tag & 7)
          continue
        }
        var entry = try event.readMessage()
        _ = try entry.readTag()
        keys.append(try entry.readString())
      }
    }
    return keys
  }

  private func utf16Precedes(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf16.lexicographicallyPrecedes(rhs.utf16)
  }
}

private enum Alphabet {
  case ascii
  case unicode

  var scalars: [Unicode.Scalar] {
    let ascii: [Unicode.Scalar] = ["a", "b", "z", "A", "Z", "0", "9", "_", "$", "-", " ", "\""]
    switch self {
    case .ascii:
      return ascii
    case .unicode:
      return ascii + [
        "\u{0}", "\u{1F}", "\u{E9}", "\u{FC}", "\u{301}", "\u{20AC}", "\u{65E5}", "\u{FF5E}", "\u{FFFD}",
        "\u{1F30D}", "\u{1F3FD}", "\u{10FFFF}",
      ]
    }
  }
}

/// Random domain values, the same on every run.
private struct Fixtures {
  private var random: SeededRandom

  init(seed: UInt64) {
    random = SeededRandom(seed: seed)
  }

  /// An event whose map keys come from `keys`. Its ids are set unless `emptyIds`, which leaves
  /// some empty: the encoder omits those, where the reference messages set them.
  mutating func event(keys: Alphabet, emptyIds: Bool = false) -> Event {
    Event(
      eventId: id(emptyIds),
      kind: string(.ascii, length: emptyIds ? 0...12 : 1...12),
      distinctId: string(.unicode, length: emptyIds ? 0...12 : 1...12),
      sessionId: id(emptyIds),
      occurTimeMillis: millis(),
      autoProperties: properties(keys, prefix: "$"),
      customProperties: properties(keys, prefix: "")
    )
  }

  mutating func string(_ alphabet: Alphabet, length: ClosedRange<Int> = 0...12) -> String {
    var scalars = String.UnicodeScalarView()
    for _ in 0..<Int.random(in: length, using: &random) {
      scalars.append(pick(alphabet.scalars))
    }
    return String(scalars)
  }

  mutating func uint32() -> UInt32 {
    .random(in: .min ... .max, using: &random)
  }

  mutating func count(_ range: ClosedRange<Int>) -> Int {
    .random(in: range, using: &random)
  }

  mutating func bytes(count range: ClosedRange<Int>) -> [UInt8] {
    (0..<count(range)).map { _ in .random(in: .min ... .max, using: &random) }
  }

  private mutating func id(_ mayBeEmpty: Bool) -> String {
    if mayBeEmpty && Bool.random(using: &random) {
      return ""
    }
    let bits = random.next()
    return UUIDv7Generator(clock: FixedClock(nowMillis: millis()), random: { bits }).nextId()
  }

  private mutating func properties(_ keys: Alphabet, prefix: String) -> [String: PropertyValue] {
    var properties: [String: PropertyValue] = [:]
    for _ in 0..<count(0...6) {
      properties[prefix + string(keys)] = value()
    }
    return properties
  }

  private mutating func value() -> PropertyValue {
    switch count(0...4) {
    case 0:
      return .string(string(.unicode))
    case 1:
      return .int(Bool.random(using: &random) ? pick([0, -1, 1, .min, .max, 127, 128, -128]) : int64())
    case 2:
      let double = Double(bitPattern: random.next())
      return .double(
        double.isFinite ? double : pick([0, -0.0, .leastNonzeroMagnitude, -.greatestFiniteMagnitude]))
    case 3:
      return .bool(Bool.random(using: &random))
    default:
      return .timestamp(epochMillis: millis())
    }
  }

  private mutating func millis() -> Int64 {
    Bool.random(using: &random)
      ? pick([0, -1, 1, -1_000, 1_000, 999, -999, .min, .max, 1_760_000_000_123]) : int64()
  }

  private mutating func int64() -> Int64 {
    .random(in: .min ... .max, using: &random)
  }

  private mutating func pick<Element>(_ elements: [Element]) -> Element {
    elements[Int.random(in: elements.indices, using: &random)]
  }
}
