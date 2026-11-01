extension Pug {
  /// Keeps the SDK's identity, consent and undelivered events. The SDK calls it from its own thread, one call at a
  /// time. If a call throws, the SDK keeps its state in memory until `Pug.destroy()` or the app restarts.
  public protocol Storage: Sendable {
    /// The value stored under `key`, or nil when there is none. Throw when a value may exist but cannot be
    /// read: nil would make the SDK start a new identity over the stored one.
    func string(forKey key: String) throws -> String?

    func setString(_ value: String, forKey key: String) throws

    func removeValue(forKey key: String) throws
  }

  /// Keeps everything in memory, so nothing outlives the process.
  public final class MemoryStorage: Storage {
    private let values = Locked<[String: String]>([:])

    public init() {}

    public func string(forKey key: String) -> String? {
      values.withLock { $0[key] }
    }

    public func setString(_ value: String, forKey key: String) {
      values.withLock { $0[key] = value }
    }

    public func removeValue(forKey key: String) {
      values.withLock { $0[key] = nil }
    }
  }
}
