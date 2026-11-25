import Foundation

struct FieldSchema: Sendable {
  // Nested, since SwiftProtobuf, which the tests import, has a FieldType of its own.
  enum ValueType: Sendable {
    case string
    case int
    case double
    case bool
    case duration
  }

  let name: String
  let type: ValueType
  let required: Bool

  init(_ name: String, _ type: ValueType, required: Bool = false) {
    self.name = name
    self.type = type
    self.required = required
  }
}

/// A well-known event: its kind, its method on `Pug.track` (if it has one), and its properties in
/// schema order.
struct EventSchema: Sendable {
  let kind: String
  let fields: [FieldSchema]
  /// The method as calls name it in logs: `track.addToCart` for `Pug.track.addToCart()`.
  let label: String

  init(kind: String, method: String, fields: [FieldSchema] = []) {
    self.kind = kind
    self.fields = fields
    label = "track.\(method)"
  }

  func field(_ name: String) -> FieldSchema? {
    fields.first { $0.name == name }
  }
}

/// What the methods of `Pug.track` call: `values` are the event's properties in schema order, nil
/// where the caller left them out.
protocol TypedTracking: Sendable {
  func trackTyped(_ event: EventSchema, _ values: [Any?], extras: [String: Any]?, options: Pug.TrackOptions?)
}
