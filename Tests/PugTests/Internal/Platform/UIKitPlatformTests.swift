#if os(iOS)
import Foundation
import Testing
import UIKit

@testable import Pug

private final class HomeViewController: UIViewController {}

private final class DetailViewController: UIViewController {}

private final class ContainerViewController: UIViewController {}

@MainActor
private final class RecordingListener: ScreenListener {
  var appeared: [String] = []
  var disappeared: [UIViewController] = []

  func viewControllerDidAppear(_ controller: UIViewController, name: String, screenClass: String) {
    appeared.append(name)
  }

  func viewControllerDidDisappear(_ controller: UIViewController) {
    disappeared.append(controller)
  }
}

/// UIKit on the simulator, without an app around the tests: one suite, run serially, since the screen tracker and the
/// app's notifications are the process's.
@MainActor
@Suite(.serialized)
struct UIKitPlatformTests {
  private let tracker = ScreenTracker.shared
  private let logger = RecordingLogger()

  init() {
    // The test bundle stands in for the app's.
    tracker.appBundleURL = Bundle(for: HomeViewController.self).bundleURL
  }

  @Test("the app's own view controllers are screens, named by their class")
  func appViewController() {
    let screen = tracker.screen(HomeViewController())

    #expect(screen?.name == "HomeViewController")
    #expect(screen?.screenClass == NSStringFromClass(HomeViewController.self))
  }

  @Test("UIKit's own view controllers are not screens")
  func systemViewControllers() {
    #expect(tracker.screen(UIViewController()) == nil)
    #expect(tracker.screen(UIAlertController(title: "Title", message: nil, preferredStyle: .alert)) == nil)
  }

  @Test("UIKit's containers are not screens, the view controllers in them are")
  func containers() {
    let home = HomeViewController()
    let navigation = UINavigationController(rootViewController: home)
    let detail = DetailViewController()
    let tabs = UITabBarController()
    tabs.viewControllers = [detail]

    #expect(tracker.screen(navigation) == nil)
    #expect(tracker.screen(tabs) == nil)
    #expect(tracker.screen(home)?.name == "HomeViewController")
    #expect(tracker.screen(detail)?.name == "DetailViewController")
  }

  @Test("a view controller in one of the app's own containers is part of that screen")
  func customContainer() {
    let container = ContainerViewController()
    let child = HomeViewController()
    container.addChild(child)
    child.didMove(toParent: container)

    #expect(tracker.screen(child) == nil)
    #expect(tracker.screen(container)?.name == "ContainerViewController")
  }

  @Test("the hooks report the screens that appear and every view controller that disappears")
  func hooks() {
    let listener = RecordingListener()
    tracker.listener = listener
    defer { tracker.listener = nil }
    let home = HomeViewController()
    let system = UIViewController()

    home.viewDidAppear(false)
    system.viewDidAppear(false)
    home.viewDidDisappear(false)
    system.viewDidDisappear(false)

    #expect(listener.appeared == ["HomeViewController"])
    #expect(listener.disappeared.count == 2)
    #expect(listener.disappeared.first === home)
  }

  @Test("the app's notifications bring it to the foreground once, take it to the background, and stop with cancel")
  func lifecycle() async throws {
    let observer = RecordingLifecycleObserver()
    let observation = try #require(UIKitPlatform().observeLifecycle(observer, screens: false, logger: logger.safe()))
    let center = NotificationCenter.default

    center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
    center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(observer.reported == [.foreground, .background])
    observer.settle()
    observation.cancel()
    center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    try await Task.sleep(nanoseconds: 100_000_000)

    #expect(observer.reported == [.foreground, .background])
  }

  @Test("a screen reaches the client through the lifecycle")
  func lifecycleScreens() async throws {
    let observer = RecordingLifecycleObserver()
    let observation = try #require(UIKitPlatform().observeLifecycle(observer, screens: true, logger: logger.safe()))
    defer { observation.cancel() }
    NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    try await Task.sleep(nanoseconds: 100_000_000)
    let home = HomeViewController()

    home.viewDidAppear(false)
    home.viewDidDisappear(false)
    home.viewDidAppear(false)

    #expect(
      observer.reported == [
        .foreground, .screen("HomeViewController", returning: false), .screenLeft,
        .screen("HomeViewController", returning: true),
      ]
    )
  }

  @Test("the device as the simulator reports it")
  func autoProperties() throws {
    let platform = UIKitPlatform()
    let observation = try #require(
      platform.observeLifecycle(RecordingLifecycleObserver(), screens: false, logger: logger.safe()))
    defer { observation.cancel() }

    let properties = PropertyMapper(logger: logger.safe()).mapAuto(
      kind: "a", platform.autoProperties(logger: logger.safe()).current())

    #expect(properties["$os"] == .string("iOS"))
    #expect(properties["$osVersion"] == .string(UIDevice.current.systemVersion))
    #expect(properties["$deviceManufacturer"] == .string("Apple"))
    #expect(properties["$device"] != nil)
    #expect(properties["$device"] == properties["$deviceModel"])
    #expect(properties["$deviceType"] == .string("mobile"))
    #expect(properties["$screenWidth"] != nil)
    #expect(properties["$screenScale"] != nil)
    #expect(properties["$networkType"] != nil)
    #expect(platform.installSource() == "com.apple.simulator")
    #expect(!platform.isAppExtension)
    #expect(platform.storageDirectory()?.lastPathComponent == "pug")
    #expect(logger.entries.isEmpty)
  }

  @Test("with protected data available, nothing waits")
  func protectedDataAvailable() {
    let ran = Locked(false)

    UIKitPlatform().whenProtectedDataAvailable(logger: logger.safe()) { ran.withLock { $0 = true } }

    #expect(ran.withLock { $0 })
  }
}
#endif
