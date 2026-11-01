import Foundation

extension Pug {
  /// Options for one tracked event.
  public struct TrackOptions: Hashable, Sendable {
    /// Sends the event on its own right away instead of with the next batch.
    public var immediate: Bool

    /// When the event happened; nil means the time of the call. A time before 1970 or after the
    /// year 9999 is logged and replaced by the time of the call.
    public var timestamp: Date?

    public init(immediate: Bool = false, timestamp: Date? = nil) {
      self.immediate = immediate
      self.timestamp = timestamp
    }
  }
}
