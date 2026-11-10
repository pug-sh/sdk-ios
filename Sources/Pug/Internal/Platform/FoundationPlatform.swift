import Foundation

/// The platform from Foundation alone: files under Application Support, and no app lifecycle or device details.
struct FoundationPlatform: Platform {
  var isAppExtension: Bool {
    false
  }

  // Outside a sandbox, as for a Mac app, Application Support is the user's, shared by every app.
  func storageDirectory() -> URL? {
    var directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    if let bundleIdentifier = Bundle.main.bundleIdentifier, !bundleIdentifier.isEmpty {
      directory = directory?.appendingPathComponent(bundleIdentifier, isDirectory: true)
    }
    return directory?.appendingPathComponent("pug", isDirectory: true)
  }

  func whenProtectedDataAvailable(logger: SafeLogger, _ work: @escaping @Sendable () -> Void) {
    work()
  }

  func autoProperties(logger: SafeLogger) -> any AutoProperties {
    NoAutoProperties()
  }

  func installSource() -> String? {
    nil
  }

  func observeLifecycle(_ observer: any LifecycleObserver, screens: Bool, logger: SafeLogger) -> (any Cancellable)? {
    nil
  }

  func runOnMain(_ work: @escaping @MainActor @Sendable () -> Void) {
    Task { @MainActor in work() }
  }

  func refreshDevice() {}
}

private struct NoAutoProperties: AutoProperties {
  var appVersion: String? {
    nil
  }

  func current() -> [String: Any] {
    [:]
  }
}
