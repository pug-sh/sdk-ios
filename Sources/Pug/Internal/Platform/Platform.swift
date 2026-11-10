import Foundation

/// What the runtime takes from the device, behind a protocol so that the runtime runs anywhere in tests.
protocol Platform: Sendable {
  /// Whether the SDK runs in an app extension, which tracks no automatic events.
  var isAppExtension: Bool { get }

  /// Where the default storage keeps its files, or nil when there is nowhere. Called on the worker.
  func storageDirectory() -> URL?

  /// Runs `work` once data protection lets the app read its files, which it does not before the first unlock after
  /// a reboot: at once unless the device is locked. Called on the worker.
  func whenProtectedDataAvailable(logger: SafeLogger, _ work: @escaping @Sendable () -> Void)

  /// The device and the app, read on the worker.
  func autoProperties(logger: SafeLogger) -> any AutoProperties

  /// Where the app was installed from, such as `com.apple`, or nil when that is not known. Called on the worker.
  func installSource() -> String?

  /// Reports the app's lifecycle to `observer`, and with `screens` the view controllers that are screens, until the
  /// returned handle is cancelled. Returns nil when there is no lifecycle to observe.
  func observeLifecycle(_ observer: any LifecycleObserver, screens: Bool, logger: SafeLogger) -> (any Cancellable)?

  /// Runs `work` on the main thread later, even when called there.
  func runOnMain(_ work: @escaping @MainActor @Sendable () -> Void)

  /// Called on the main thread, reads anew what auto-properties take from it, such as the screen's size after a
  /// rotation. Elsewhere, does nothing.
  func refreshDevice()
}

protocol AutoProperties {
  /// The app's version, which install and update tracking compare across launches.
  var appVersion: String? { get }

  /// The `$` properties of an event happening now. Called on the worker.
  func current() -> [String: Any]
}

/// The app's lifecycle, reported on the main thread.
protocol LifecycleObserver: Sendable {
  func appDidEnterForeground()

  /// `settled` runs, on any thread, once what leaving the foreground sends has settled.
  func appDidEnterBackground(then settled: @escaping @Sendable () -> Void)

  /// A view controller that is a screen appeared: `isReturning` when it is the one that appeared last.
  func screenDidAppear(name: String, screenClass: String, isReturning: Bool)

  /// The view controller that appeared last disappeared, covered by another or removed.
  func screenDidDisappear()
}
