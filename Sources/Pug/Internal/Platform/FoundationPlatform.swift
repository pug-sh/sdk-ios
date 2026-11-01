import Foundation

/// The platform from Foundation alone: files under Application Support, and no app lifecycle or device details.
struct FoundationPlatform: Platform {
  func storageDirectory() -> URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("pug", isDirectory: true)
  }

  func autoProperties(logger: SafeLogger) -> any AutoProperties {
    NoAutoProperties()
  }

  func installSource() -> String? {
    nil
  }

  func observeLifecycle(_ observer: any LifecycleObserver, logger: SafeLogger) -> (any Cancellable)? {
    nil
  }

  func runOnMain(_ work: @escaping @MainActor @Sendable () -> Void) {
    Task { @MainActor in work() }
  }
}

private struct NoAutoProperties: AutoProperties {
  var appVersion: String? {
    nil
  }

  func current() -> [String: Any] {
    [:]
  }
}
