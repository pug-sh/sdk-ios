#if os(iOS)
import UIKit

/// What `ScreenTracker` reports to, on the main thread.
@MainActor
protocol ScreenListener: AnyObject {
  /// `screenClass` is nil for a SwiftUI view that `pugScreen(_:)` names.
  func viewControllerDidAppear(_ controller: UIViewController, name: String, screenClass: String?)

  func viewControllerDidDisappear(_ controller: UIViewController)
}

/// Finds the view controllers that are screens: those of the app's own classes, other than UIKit's containers, whose
/// parent is none or one of those containers. Hooks `viewDidAppear(_:)` and `viewDidDisappear(_:)` of every view
/// controller once per process, the first time they are asked for; the hooks stay, reporting nothing while they are
/// not. The SwiftUI views that `pugScreen(_:)` names report through it either way.
@MainActor
final class ScreenTracker {
  struct Screen: Equatable {
    let name: String
    let screenClass: String
  }

  static let shared = ScreenTracker()

  /// Hears of the screens that appear and of the view controllers that disappear, from `start` to `stop`.
  private(set) weak var listener: (any ScreenListener)?
  private var tracksViewControllers = false

  /// Where the app's own classes live: its executable and the frameworks it embeds.
  var appBundleURL = Bundle.main.bundleURL {
    didSet {
      screens = [:]
    }
  }

  private var isHooked = false
  // By class, nil for one that is not the app's own.
  private var screens: [ObjectIdentifier: Screen?] = [:]

  /// Reports to `listener` the SwiftUI views the app names and, with `viewControllers`, the view controllers.
  func start(_ listener: any ScreenListener, viewControllers: Bool) {
    self.listener = listener
    tracksViewControllers = viewControllers
    if viewControllers {
      installHooks()
    }
  }

  func stop(_ listener: any ScreenListener) {
    guard self.listener === listener else { return }
    self.listener = nil
    tracksViewControllers = false
  }

  func namedScreenDidAppear(_ controller: NamedScreenController) {
    listener?.viewControllerDidAppear(controller, name: controller.name, screenClass: nil)
  }

  func namedScreenDidDisappear(_ controller: NamedScreenController) {
    listener?.viewControllerDidDisappear(controller)
  }

  /// What `controller` reports as a screen, or nil when it is not one. A named SwiftUI view reports itself.
  func screen(_ controller: UIViewController) -> Screen? {
    guard !(controller is NamedScreenController), !Self.isContainer(controller),
      controller.parent.map(Self.isContainer) ?? true
    else { return nil }
    let viewControllerClass: AnyClass = type(of: controller)
    let key = ObjectIdentifier(viewControllerClass)
    if let known = screens[key] {
      return known
    }
    let screen = isAppClass(viewControllerClass) ? Self.describe(viewControllerClass) : nil
    screens.updateValue(screen, forKey: key)
    return screen
  }

  private nonisolated static func isContainer(_ controller: UIViewController) -> Bool {
    controller is UINavigationController || controller is UITabBarController || controller is UISplitViewController
      || controller is UIPageViewController
  }

  private static func describe(_ viewControllerClass: AnyClass) -> Screen {
    let screenClass = NSStringFromClass(viewControllerClass)
    let name = String(describing: viewControllerClass)
    return Screen(name: name.isEmpty ? screenClass : name, screenClass: screenClass)
  }

  // By the path of the class's image: Bundle(for:) may read the disk, and this runs on the main thread.
  private func isAppClass(_ viewControllerClass: AnyClass) -> Bool {
    guard let image = class_getImageName(viewControllerClass) else { return false }
    return String(cString: image).hasPrefix(appBundleURL.path + "/")
  }

  private func didAppear(_ controller: UIViewController) {
    guard tracksViewControllers, let listener, let screen = screen(controller) else { return }
    listener.viewControllerDidAppear(controller, name: screen.name, screenClass: screen.screenClass)
  }

  private func didDisappear(_ controller: UIViewController) {
    guard tracksViewControllers, !(controller is NamedScreenController) else { return }
    listener?.viewControllerDidDisappear(controller)
  }

  private func installHooks() {
    guard !isHooked else { return }
    isHooked = true
    Self.hook(#selector(UIViewController.viewDidAppear(_:))) { ScreenTracker.shared.didAppear($0) }
    Self.hook(#selector(UIViewController.viewDidDisappear(_:))) { ScreenTracker.shared.didDisappear($0) }
  }

  // Replaces UIViewController's own implementation, which every subclass reaches through super, with one that calls
  // it and then reports.
  private nonisolated static func hook(
    _ selector: Selector,
    _ report: @escaping @MainActor @Sendable (UIViewController) -> Void
  ) {
    typealias Implementation = @convention(c) (UIViewController, Selector, Bool) -> Void
    guard let method = class_getInstanceMethod(UIViewController.self, selector) else { return }
    let original = unsafeBitCast(method_getImplementation(method), to: Implementation.self)
    let replacement: @convention(block) (UIViewController, Bool) -> Void = { controller, animated in
      original(controller, selector, animated)
      // UIKit calls these on the main thread; a call from elsewhere is the host's, passed on but not tracked.
      if Thread.isMainThread {
        MainActor.assumeIsolated { report(controller) }
      }
    }
    method_setImplementation(method, imp_implementationWithBlock(replacement))
  }
}
#endif
