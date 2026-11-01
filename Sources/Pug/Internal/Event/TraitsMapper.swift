/// Maps identify traits onto `google.protobuf.Struct` values; nesting is kept, unlike properties. A
/// trait that is nil is sent as null.
struct TraitsMapper: Sendable {
  let logger: SafeLogger

  func map(_ traits: [String: Any]) -> [String: JSONValue] {
    var mapped: [String: JSONValue] = [:]
    for (key, value) in traits.sortedByUTF16Key() {
      let value = HostValue(value)
      if case .decimal(let decimal) = value, !decimal.isFinite {
        logger.warning("Trait \"\(key)\" was dropped: it is not a finite number")
        continue
      }
      do {
        var json = HostJSON()
        mapped[key] = try json.convert(value)
      } catch {
        logger.warning("Trait \"\(key)\" was dropped: \(error.reason)")
      }
    }
    return mapped
  }
}
