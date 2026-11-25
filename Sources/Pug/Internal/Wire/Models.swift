enum PropertyValue: Equatable, Sendable {
  case string(String)
  case int(Int64)
  case double(Double)
  case bool(Bool)
  case timestamp(epochMillis: Int64)
  // Normalized as google.protobuf.Duration requires: nanos within a second, of the sign of seconds.
  case duration(seconds: Int64, nanos: Int32)
}

struct Event: Equatable, Sendable {
  var eventId: String
  var kind: String
  var distinctId: String
  var sessionId: String
  var occurTimeMillis: Int64
  var autoProperties: [String: PropertyValue]
  var customProperties: [String: PropertyValue]
}

enum JSONValue: Equatable, Sendable {
  case null
  case number(Double)
  case string(String)
  case bool(Bool)
  case object([String: JSONValue])
  case array([JSONValue])
}

struct IdentifyRequest: Equatable, Sendable {
  var externalId: String
  var traits: [String: JSONValue]
  var anonymousId: String?
}

struct BatchCreateResponse: Equatable, Sendable {
  var accepted: Int64
  var droppedByReason: [String: Int64]
  var invalidEvents: [InvalidEvent] = []
}

struct InvalidEvent: Equatable, Sendable {
  /// The event's position in the batch sent.
  var index: Int64
  var violations: [String]
}
