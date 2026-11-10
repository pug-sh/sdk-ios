/// The app's lifecycle as the main thread sees it, from the platform's notifications and view controller hooks. The
/// app is in the foreground from the first sign of it until it enters the background, where a background task keeps it
/// running until what leaving sends has settled. A screen that appears while the app is not in the foreground, as in a
/// launch in the background, is reported once the app comes to it. Confined to the main thread.
@MainActor
final class AppLifecycleTracker {
  private struct Screen {
    weak var controller: AnyObject?
    weak var layer: AnyObject?
    let name: String
    let screenClass: String
  }

  // A screen left in view beneath a presentation, such as a sheet, whose dismissal UIKit reports to no view controller
  // beneath it.
  private struct Covered {
    weak var layer: AnyObject?
    let screen: Screen
  }

  private let observer: any LifecycleObserver
  private let beginBackgroundTask: @MainActor @Sendable () -> @Sendable () -> Void
  private var isForeground = false
  private var isStopped = false
  // The screen reported last, which returns when what covered it goes, and whether it has disappeared since.
  private var screen: Screen?
  private var isScreenHidden = false
  private var covered: [Covered] = []
  private var pending: Screen?

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
      report(pending)
    }
  }

  func enterBackground() {
    guard !isStopped else { return }
    isForeground = false
    observer.appDidEnterBackground(then: beginBackgroundTask())
  }

  /// `controller` is a view controller that is a screen, and `layer` the root of its hierarchy: the window's root view
  /// controller, or a presented one.
  func screenDidAppear(_ controller: AnyObject, layer: AnyObject, name: String, screenClass: String) {
    guard !isStopped else { return }
    show(Screen(controller: controller, layer: layer, name: name, screenClass: screenClass))
  }

  /// `isDismissed` when `controller` goes with the dismissal of the presentation it is in.
  func screenDidDisappear(_ controller: AnyObject, isDismissed: Bool) {
    guard !isStopped else { return }
    if pending?.controller === controller {
      pending = nil
    }
    covered.removeAll { $0.layer == nil || $0.screen.controller == nil || $0.screen.controller === controller }
    guard let current = screen, current.controller === controller else { return }
    isScreenHidden = true
    if isDismissed, let index = covered.lastIndex(where: { $0.layer === current.layer }) {
      show(covered.remove(at: index).screen)
    } else {
      observer.screenDidDisappear()
    }
  }

  /// Ignores what is reported from here on.
  func stop() {
    isStopped = true
    pending = nil
    covered = []
  }

  private func show(_ shown: Screen) {
    if isForeground {
      report(shown)
    } else {
      pending = shown
    }
  }

  private func report(_ shown: Screen) {
    guard let controller = shown.controller else { return }
    if let current = screen, current.controller != nil, current.layer !== shown.layer, !isScreenHidden {
      covered.append(Covered(layer: shown.layer, screen: current))
    }
    let isReturning = screen?.controller === controller
    screen = shown
    isScreenHidden = false
    observer.screenDidAppear(name: shown.name, screenClass: shown.screenClass, isReturning: isReturning)
  }
}
