#if os(iOS)
import UIKit

/// The platform of an iOS app: UIKit's lifecycle and view controllers, and the device. An app extension, which cannot
/// use `UIApplication.shared`, has no lifecycle to observe and tracks no automatic events.
final class UIKitPlatform: Platform {
  // In an app extension, the main bundle is the extension's own.
  private static let isExtension = Bundle.main.bundleURL.pathExtension == "appex"

  private let foundation = FoundationPlatform()
  // What the main thread read last, for every client.
  private let snapshot = Locked<DeviceSnapshot?>(nil)
  // Started with the first call to Pug, so that it has likely reported by the first event.
  private let network = NetworkMonitor.shared

  var isAppExtension: Bool {
    Self.isExtension
  }

  /// `UIApplication.shared`, which code that an app extension links may not name. Nil in an extension, and until
  /// UIKit has made the application.
  @MainActor
  static func application() -> UIApplication? {
    guard !isExtension else { return nil }
    let shared = NSSelectorFromString("sharedApplication")
    guard UIApplication.responds(to: shared) else { return nil }
    return UIApplication.perform(shared)?.takeUnretainedValue() as? UIApplication
  }

  func storageDirectory() -> URL? {
    foundation.storageDirectory()
  }

  func whenProtectedDataAvailable(logger: SafeLogger, _ work: @escaping @Sendable () -> Void) {
    onMain {
      guard let application = UIKitPlatform.application(), !application.isProtectedDataAvailable else {
        work()
        return
      }
      logger.debug("Storage cannot be read until the device is unlocked; Pug starts then")
      ProtectedDataWaiter.wait(then: work)
    }
  }

  func autoProperties(logger: SafeLogger) -> any AutoProperties {
    let bundle = Bundle.main
    let network = network
    return DeviceAutoProperties(
      info: bundle.infoDictionary ?? [:],
      bundleIdentifier: bundle.bundleIdentifier,
      model: Self.modelIdentifier(),
      runsOnMac: ProcessInfo.processInfo.isMacCatalystApp,
      snapshot: snapshot,
      environment: DeviceEnvironment(
        preferredLanguage: { Locale.preferredLanguages.first },
        regionCode: { Locale.autoupdatingCurrent.regionCode },
        timeZone: { TimeZone.autoupdatingCurrent.identifier },
        networkType: { network.networkType }
      )
    )
  }

  func installSource() -> String? {
    #if targetEnvironment(simulator)
    return InstallSource.of(receiptURL: nil, isSimulator: true)
    #else
    return InstallSource.of(receiptURL: Bundle.main.appStoreReceiptURL, isSimulator: false)
    #endif
  }

  func observeLifecycle(_ observer: any LifecycleObserver, screens: Bool, logger: SafeLogger) -> (any Cancellable)? {
    let snapshot = snapshot
    guard !Self.isExtension else {
      onMain { UIKitLifecycle.refresh(snapshot) }
      return nil
    }
    let lifecycle = UIKitLifecycle(observer: observer, screens: screens, snapshot: snapshot)
    onMain { lifecycle.start() }
    return lifecycle
  }

  func runOnMain(_ work: @escaping @MainActor @Sendable () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated(work) }
  }

  func refreshDevice() {
    guard Thread.isMainThread else { return }
    let snapshot = snapshot
    MainActor.assumeIsolated { UIKitLifecycle.refresh(snapshot) }
  }

  // The simulated device's on a simulator, and the Mac's for an app running on one.
  private static func modelIdentifier() -> String? {
    #if targetEnvironment(simulator)
    return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]
    #else
    return systemValue(ProcessInfo.processInfo.isMacCatalystApp ? "hw.model" : "hw.machine")
    #endif
  }

  private static func systemValue(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var bytes = [UInt8](repeating: 0, count: size)
    guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
    let value = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    return value.isEmpty ? nil : value
  }
}

/// One client's observation of UIKit, on the main thread: the app's notifications, its view controllers and what only
/// the main thread can read for auto-properties. Started and cancelled from any thread, in the order called, so that a
/// cancel that overtakes a pending start leaves nothing observed.
@MainActor
private final class UIKitLifecycle: Cancellable, ScreenListener {
  private let tracker: AppLifecycleTracker
  private let screens: Bool
  private let snapshot: Locked<DeviceSnapshot?>
  private var observations: [any NSObjectProtocol] = []
  private var isCancelled = false

  nonisolated init(observer: any LifecycleObserver, screens: Bool, snapshot: Locked<DeviceSnapshot?>) {
    tracker = AppLifecycleTracker(observer: observer) { BackgroundTask.begin() }
    self.screens = screens
    self.snapshot = snapshot
  }

  static func refresh(_ snapshot: Locked<DeviceSnapshot?>) {
    let device = UIDevice.current
    let screen = UIScreen.main
    let current = DeviceSnapshot(
      osVersion: device.systemVersion,
      isPhone: device.userInterfaceIdiom == .phone,
      screenWidth: Double(screen.bounds.width),
      screenHeight: Double(screen.bounds.height),
      screenScale: Double(screen.scale)
    )
    snapshot.withLock { $0 = current }
  }

  func start() {
    guard !isCancelled else { return }
    Self.refresh(snapshot)
    // Whichever comes first: returning from the background, the app enters the foreground before it becomes
    // active, while a launch only becomes active. Resigning active, as for Control Center or a call, is no exit.
    observations = [
      observe(UIApplication.willEnterForegroundNotification) { $0.enterForeground() },
      observe(UIApplication.didBecomeActiveNotification) { $0.enterForeground() },
      observe(UIApplication.didEnterBackgroundNotification) { $0.enterBackground() },
    ]
    if screens {
      ScreenTracker.shared.listener = self
    }
    // A launch in the background, or one not yet active, waits for the notifications.
    if Self.isActive() {
      enterForeground()
    }
  }

  nonisolated func cancel() {
    onMain { self.stop() }
  }

  func viewControllerDidAppear(_ controller: UIViewController, name: String, screenClass: String) {
    Self.refresh(snapshot)
    tracker.screenDidAppear(controller, layer: Self.root(of: controller), name: name, screenClass: screenClass)
  }

  func viewControllerDidDisappear(_ controller: UIViewController) {
    tracker.screenDidDisappear(controller, isDismissed: Self.root(of: controller).isBeingDismissed)
  }

  private static func isActive() -> Bool {
    UIKitPlatform.application()?.applicationState == .active
  }

  // A presented view controller has no parent, so this is the presented one or the window's root.
  private static func root(of controller: UIViewController) -> UIViewController {
    var root = controller
    while let parent = root.parent {
      root = parent
    }
    return root
  }

  private func enterForeground() {
    Self.refresh(snapshot)
    tracker.enterForeground()
  }

  private func enterBackground() {
    Self.refresh(snapshot)
    tracker.enterBackground()
  }

  private func stop() {
    isCancelled = true
    tracker.stop()
    for observation in observations {
      NotificationCenter.default.removeObserver(observation)
    }
    observations = []
    if ScreenTracker.shared.listener === self {
      ScreenTracker.shared.listener = nil
    }
  }

  private func observe(
    _ name: Notification.Name,
    _ action: @escaping @MainActor @Sendable (UIKitLifecycle) -> Void
  ) -> any NSObjectProtocol {
    NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
      guard let self else { return }
      MainActor.assumeIsolated { action(self) }
    }
  }
}

/// Keeps the app running in the background while leaving the foreground sends, until those settle or iOS ends it.
@MainActor
private final class BackgroundTask {
  private let application: UIApplication
  private var identifier = UIBackgroundTaskIdentifier.invalid

  private init(_ application: UIApplication) {
    self.application = application
  }

  /// Returns what ends the task, from any thread.
  static func begin() -> @Sendable () -> Void {
    guard let application = UIKitPlatform.application() else { return {} }
    let task = BackgroundTask(application)
    task.identifier = application.beginBackgroundTask(withName: "Pug") { task.end() }
    return { onMain { task.end() } }
  }

  private func end() {
    guard identifier != .invalid else { return }
    application.endBackgroundTask(identifier)
    identifier = .invalid
  }
}

/// Runs work once the device is unlocked, or the app becomes active, which it cannot be while locked.
@MainActor
private final class ProtectedDataWaiter {
  private var work: (@Sendable () -> Void)?
  private var observations: [any NSObjectProtocol] = []

  static func wait(then work: @escaping @Sendable () -> Void) {
    let waiter = ProtectedDataWaiter()
    waiter.work = work
    let names = [UIApplication.protectedDataDidBecomeAvailableNotification, UIApplication.didBecomeActiveNotification]
    waiter.observations = names.map { name in
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { waiter.finish() }
      }
    }
  }

  private func finish() {
    guard let work else { return }
    self.work = nil
    for observation in observations {
      NotificationCenter.default.removeObserver(observation)
    }
    observations = []
    work()
  }
}

/// Runs `work` at once on the main thread, else on its next turn.
private func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
  if Thread.isMainThread {
    MainActor.assumeIsolated(work)
  } else {
    DispatchQueue.main.async { MainActor.assumeIsolated(work) }
  }
}
#endif
