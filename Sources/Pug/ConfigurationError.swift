import Foundation

extension Pug {
  /// Why `Pug.initialize(projectId:options:)` refused its arguments.
  public struct ConfigurationError: Error, Hashable, CustomStringConvertible, LocalizedError {
    /// What to fix, such as "Pug.initialize() needs a project id".
    public let message: String

    init(_ message: String) {
      self.message = message
    }

    public var description: String {
      message
    }

    public var errorDescription: String? {
      message
    }
  }
}
