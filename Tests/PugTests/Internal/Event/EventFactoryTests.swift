import Foundation
import Testing

@testable import Pug

struct EventFactoryTests {
  private let logger = RecordingLogger()
  private var factory: EventFactory {
    EventFactory(
      projectId: "proj_1",
      logger: logger.safe(),
      properties: PropertyMapper(logger: logger.safe()),
      ids: ids
    )
  }
  private let ids = SequentialIds()

  @Test("kinds follow the server's pattern")
  func validKinds() {
    for kind in ["app_open", "Checkout.Started-v2", "a", "0"] {
      #expect(factory.acceptsKind(kind), "\(kind)")
    }
    #expect(logger.entries.isEmpty)

    for kind in ["add to cart", "a/b", "\u{FC}mlaut", "emoji\u{1F30D}", "tab\t"] {
      #expect(!factory.acceptsKind(kind), "\(kind)")
    }
    #expect(
      logger.warnings.first
        == "Event \"add to cart\" was dropped: a kind may only contain letters, digits, '_', '.' and '-'"
    )
    #expect(logger.warnings.count == 5)
  }

  @Test("blank kinds are dropped")
  func blankKinds() {
    #expect(!factory.acceptsKind(""))
    #expect(!factory.acceptsKind("  "))

    #expect(logger.warnings == Array(repeating: "An event with a blank kind was dropped", count: 2))
  }

  @Test("an event happens at its timestamp, or at the call when it has none")
  func occurTime() {
    let last = Limits.occurTimeMillis.upperBound

    #expect(factory.occurTime(kind: "kind", timestamp: nil, callTimeMillis: 500) == 500)
    #expect(factory.occurTime(kind: "kind", timestamp: Date(timeIntervalSince1970: 0), callTimeMillis: 500) == 0)
    #expect(factory.occurTime(kind: "kind", timestamp: date(millis: last), callTimeMillis: 500) == last)
    #expect(logger.entries.isEmpty)
  }

  @Test("an unusable timestamp is replaced by the time of the call")
  func unusableTimestamps() {
    let last = Limits.occurTimeMillis.upperBound

    #expect(factory.occurTime(kind: "kind", timestamp: date(millis: -1), callTimeMillis: 500) == 500)
    #expect(factory.occurTime(kind: "kind", timestamp: date(millis: last + 1), callTimeMillis: 500) == 500)
    #expect(
      factory.occurTime(kind: "kind", timestamp: Date(timeIntervalSince1970: .nan), callTimeMillis: 500) == 500
    )

    #expect(
      logger.warnings == [
        "Event \"kind\" has a timestamp outside 1970 to 9999 (-1 ms since 1970); using the time of the call",
        "Event \"kind\" has a timestamp outside 1970 to 9999 (253402300800000 ms since 1970); using the time "
          + "of the call",
        "Event \"kind\" has a timestamp outside 1970 to 9999 (nan s since 1970); using the time of the call",
      ]
    )
  }

  @Test("events carry identity, time, properties and the SDK's own auto-properties")
  func carriesEverything() {
    let event = factory.create(
      kind: "add_to_cart",
      customProperties: ["productId": .string("p1"), "price": .double(9.99)],
      autoProperties: ["$os": "iOS", "$platform": "spoofed", "$projectId": "other"],
      distinctId: "anon-1",
      sessionId: "00000000-0000-7000-8000-0000000000aa",
      occurTimeMillis: 1_760_000_000_000
    )

    let expected = Event(
      eventId: "00000000-0000-7000-8000-000000000001",
      kind: "add_to_cart",
      distinctId: "anon-1",
      sessionId: "00000000-0000-7000-8000-0000000000aa",
      occurTimeMillis: 1_760_000_000_000,
      autoProperties: [
        "$os": .string("iOS"),
        "$platform": .string("ios"),
        "$projectId": .string("proj_1"),
        "$sdkVersion": .string(sdkVersion),
      ],
      customProperties: ["productId": .string("p1"), "price": .double(9.99)]
    )
    #expect(event == expected)
  }

  @Test("each event gets a new id")
  func newIds() throws {
    let first = try #require(create())
    let second = try #require(create())

    #expect(first.eventId == "00000000-0000-7000-8000-000000000001")
    #expect(second.eventId == "00000000-0000-7000-8000-000000000002")
  }

  @Test("an event too large for any request is dropped")
  func tooLarge() throws {
    let value = PropertyValue.string(String(repeating: "x", count: Limits.maxStringBytes))
    let tooMany = Dictionary(uniqueKeysWithValues: (0..<4_100).map { ("p\($0)", value) })

    #expect(create(tooMany) == nil)

    let error = try #require(logger.errors.first)
    #expect(logger.errors.count == 1)
    #expect(error.hasPrefix("Event \"kind\" was dropped: it encodes to "))
    #expect(error.hasSuffix(" bytes, over the 4194304-byte request limit"))
  }

  @Test("an event just under the request limit is kept")
  func underTheLimit() throws {
    let value = PropertyValue.string(String(repeating: "x", count: Limits.maxStringBytes))
    let many = Dictionary(uniqueKeysWithValues: (0..<4_000).map { ("p\($0)", value) })

    let event = try #require(create(many))

    #expect(Wire.eventSize(event) <= Limits.maxBatchBytes)
  }

  private func create(_ properties: [String: PropertyValue] = [:]) -> Event? {
    factory.create(
      kind: "kind",
      customProperties: properties,
      autoProperties: [:],
      distinctId: "anon-1",
      sessionId: "00000000-0000-7000-8000-0000000000aa",
      occurTimeMillis: 0
    )
  }

  private func date(millis: Int64) -> Date {
    Date(timeIntervalSince1970: Double(millis) / 1_000)
  }
}
