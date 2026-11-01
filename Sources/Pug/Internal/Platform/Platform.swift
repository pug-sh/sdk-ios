import Foundation

/// What the runtime takes from the device, behind a protocol so that the runtime runs anywhere in tests.
protocol Platform: Sendable {
  /// Where the default storage keeps its files, or nil when there is nowhere. Called on the worker.
  func storageDirectory() -> URL?

  /// The device and the app, read on the worker.
  func autoProperties(logger: SafeLogger) -> any AutoProperties

  /// Where the app was installed from, such as `com.apple`, or nil when that is not known. Called on the worker.
  func installSource() -> String?

  /// Reports the app's lifecycle to `observer` until the returned handle is cancelled, or returns nil when there is
  /// no lifecycle to observe.
  func observeLifecycle(_ observer: any LifecycleObserver, logger: SafeLogger) -> (any Cancellable)?

  /// Runs `work` on the main thread later, even when called there.
  func runOnMain(_ work: @escaping @MainActor @Sendable () -> Void)
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

  func screenDidAppear(name: String, screenClass: String)
}
