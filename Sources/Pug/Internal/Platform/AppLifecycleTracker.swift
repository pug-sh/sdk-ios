/// The app's lifecycle as the main thread sees it, from the platform's notifications and view controller hooks. The
/// app is in the foreground from the first sign of it until it enters the background, where a background task keeps it
/// running until what leaving sends has settled. A screen that appears while the app is not in the foreground, as in a
/// launch in the background, is reported once the app comes to it. Confined to the main thread.
@MainActor
final class AppLifecycleTracker {
  private struct PendingScreen {
    weak var controller: AnyObject?
    let name: String
    let screenClass: String
  }

  private let observer: any LifecycleObserver
  private let beginBackgroundTask: @MainActor @Sendable () -> @Sendable () -> Void
  private var isForeground = false
  private var isStopped = false
  // The screen reported last, which returns when what covered it goes.
  private weak var screen: AnyObject?
  private var pending: PendingScreen?

  /// `beginBackgroundTask` returns what ends the task, from any thread.
  nonisolated init(
    observer: any LifecycleObserver,
    beginBackgroundTask: @escaping @MainActor @Sendable () -> @Sendable () -> Void
  ) {
    self.observer = observer
    self.beginBackgroundTask = beginBackgroundTask
  }

  func enterForeground() {
    guard !isStopped, !isForeground else { return }
    isForeground = true
    observer.appDidEnterForeground()
    if let pending {
      self.pending = nil
      if let controller = pending.controller {
        report(controller, name: pending.name, screenClass: pending.screenClass)
      }
    }
  }

  func enterBackground() {
    guard !isStopped else { return }
    isForeground = false
    observer.appDidEnterBackground(then: beginBackgroundTask())
  }

  /// `controller` is a view controller that is a screen.
  func screenDidAppear(_ controller: AnyObject, name: String, screenClass: String) {
    guard !isStopped else { return }
    if isForeground {
      report(controller, name: name, screenClass: screenClass)
    } else {
      pending = PendingScreen(controller: controller, name: name, screenClass: screenClass)
    }
  }

  func screenDidDisappear(_ controller: AnyObject) {
    guard !isStopped else { return }
    if pending?.controller === controller {
      pending = nil
    }
    if controller === screen {
      observer.screenDidDisappear()
    }
  }

  /// Ignores what is reported from here on.
  func stop() {
    isStopped = true
    pending = nil
  }

  private func report(_ controller: AnyObject, name: String, screenClass: String) {
    let isReturning = controller === screen
    screen = controller
    observer.screenDidAppear(name: name, screenClass: screenClass, isReturning: isReturning)
  }
}
