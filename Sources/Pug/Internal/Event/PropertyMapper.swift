import Foundation

/// Maps host values onto `PropertyValue`, dropping what the server would reject: one bad value would cost its whole
/// event, and on a server before v0.0.55 the events sent alongside it too. Keys are read in order, so warnings come
/// out the same way every run.
struct PropertyMapper: Sendable {
  let logger: SafeLogger

  /// Custom properties may not start with `$`, which is reserved for auto-properties.
  func mapCustom(kind: String, _ properties: [String: Any]) -> [String: PropertyValue] {
    map(kind: kind, properties, auto: false)
  }

  /// Auto-property keys must start with `$`.
  func mapAuto(kind: String, _ properties: [String: Any]) -> [String: PropertyValue] {
    map(kind: kind, properties, auto: true)
  }

  /// The custom properties of a call to `Pug.track.<event>(...)`: `values` are `event`'s properties in
  /// schema order, nil where left out, and win over `extras` of their names.
  func mapTyped(_ event: EventSchema, values: [Any?], extras: [String: Any]?) -> [String: PropertyValue] {
    assert(values.count == event.fields.count, "\(event.label) passed \(values.count) values")
    let caller = "Pug.\(event.label)()"
    var typed: [String: Any] = [:]
    var durations: [String: PropertyValue] = [:]
    for (field, value) in zip(event.fields, values) {
      guard let value else { continue }
      guard field.type == .duration, let seconds = value as? TimeInterval else {
        typed[field.name] = value
        continue
      }
      do {
        durations[field.name] = try duration(seconds: seconds)
      } catch {
        logger.warning("Property \"\(field.name)\" on event \"\(event.kind)\" was dropped: \(error.reason)")
      }
    }
    var custom = extras.map { mapCustom(kind: event.kind, $0) } ?? [:]
    let own = mapCustom(kind: event.kind, typed).merging(durations) { $1 }
    for (name, value) in own.sortedByUTF16Key() {
      if custom.updateValue(value, forKey: name) != nil {
        logger.warning("Extra \"\(name)\" of \(caller) was dropped: the event's own \(name) is set")
      }
    }
    // Checked on what is sent, since the mapper can drop a required property. The server takes the
    // event without it, as it does from Pug.track(_:properties:options:).
    let missing = event.fields.filter { $0.required && custom[$0.name] == nil }.map(\.name)
    if !missing.isEmpty {
      logger.warning("\(caller) was tracked without its required \(missing.joined(separator: ", "))")
    }
    return custom
  }

  private func map(kind: String, _ properties: [String: Any], auto: Bool) -> [String: PropertyValue] {
    let schema = auto ? nil : WellKnownEvents.byKind[kind]
    var mapped: [String: PropertyValue] = [:]
    for (key, value) in properties.sortedByUTF16Key() {
      guard let value = HostValue(value) else { continue }
      guard key.hasUTF8Prefix("$") == auto else {
        if auto {
          logger.warning("Auto-property \"\(key)\" was dropped: auto-property keys start with '$'")
        } else {
          logger.warning(
            "Property \"\(key)\" on event \"\(kind)\" was dropped: keys starting with '$' are reserved")
        }
        continue
      }
      do {
        mapped[key] = coerce(schema, key, truncate(kind, key, try propertyValue(value)))
      } catch {
        logger.warning("Property \"\(key)\" on event \"\(kind)\" was dropped: \(error.reason)")
      }
    }
    return mapped
  }

  private func propertyValue(_ value: HostValue) throws(UnsupportedValue) -> PropertyValue {
    switch value {
    case .text(let text), .digits(let text), .other(let text):
      return .string(text)
    case .bool(let bool):
      return .bool(bool)
    case .integer(let integer):
      return .int(integer)
    case .decimal(let decimal):
      guard decimal.isFinite else { throw UnsupportedValue("\(decimal) is not a finite number") }
      return .double(decimal)
    case .date(let date):
      guard let millis = date.epochMillis, Limits.timestampMillis.contains(millis) else {
        throw .outOfRangeTime
      }
      return .timestamp(epochMillis: millis)
    case .duration(let seconds, let attoseconds):
      guard let duration = PropertyValue.duration(seconds: seconds, attoseconds: attoseconds) else {
        throw .outOfRangeDuration
      }
      return duration
    case .array, .set, .object:
      var json = HostJSON()
      return .string(try json.convert(value).text)
    }
  }

  private func duration(seconds: TimeInterval) throws(UnsupportedValue) -> PropertyValue {
    guard seconds.isFinite else { throw UnsupportedValue("\(seconds) is not a finite number") }
    guard let duration = PropertyValue.duration(seconds: seconds) else { throw .outOfRangeDuration }
    return duration
  }

  // A double-typed property of a well-known event gets one column type, even from `price: 10`.
  private func coerce(_ schema: EventSchema?, _ key: String, _ value: PropertyValue) -> PropertyValue {
    guard case .int(let integer) = value, schema?.field(key)?.type == .double else { return value }
    return .double(Double(integer))
  }

  private func truncate(_ kind: String, _ key: String, _ value: PropertyValue) -> PropertyValue {
    guard case .string(let string) = value else { return value }
    let truncated = string.truncatedUTF8(maxBytes: Limits.maxStringBytes)
    if truncated.utf8.count == string.utf8.count {
      return value
    }
    logger.warning("Property \"\(key)\" on event \"\(kind)\" was truncated to \(Limits.maxStringBytes) bytes")
    return .string(truncated)
  }
}
