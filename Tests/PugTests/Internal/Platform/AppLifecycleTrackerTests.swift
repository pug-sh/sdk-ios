import Testing

@testable import Pug

@MainActor
struct AppLifecycleTrackerTests {
  /// Stands in for a view controller.
  private final class Controller {}

  private let observer = RecordingLifecycleObserver()
  private let tasks = Locked<[String]>([])
  private let tracker: AppLifecycleTracker
  // The window's root view controller.
  private let window = Controller()

  init() {
    let tasks = tasks
    tracker = AppLifecycleTracker(observer: observer) {
      tasks.withLock { $0.append("begin") }
      return { tasks.withLock { $0.append("end") } }
    }
  }

  @Test("the app is in the foreground from the first sign of it until it enters the background")
  func foreground() {
    tracker.enterForeground()
    tracker.enterForeground()
    tracker.enterBackground()
    tracker.enterForeground()

    #expect(observer.reported == [.foreground, .background, .foreground])
  }

  @Test("entering the background runs a background task until its sends settle")
  func backgroundTask() {
    tracker.enterForeground()
    tracker.enterBackground()
    #expect(tasks.withLock { $0 } == ["begin"])

    observer.settle()

    #expect(tasks.withLock { $0 } == ["begin", "end"])
  }

  @Test("entering the background is reported even when the app never came to the foreground")
  func backgroundWithoutForeground() {
    tracker.enterBackground()

    #expect(observer.reported == [.background])
  }

  @Test("a screen is reported as it appears, and returning when it is the one shown last")
  func screens() {
    let home = Controller()
    let detail = Controller()
    tracker.enterForeground()

    tracker.screenDidAppear(home, layer: window, name: "Home", screenClass: "Shop.Home")
    tracker.screenDidAppear(detail, layer: window, name: "Detail", screenClass: "Shop.Detail")
    tracker.screenDidAppear(detail, layer: window, name: "Detail", screenClass: "Shop.Detail")
    tracker.screenDidAppear(home, layer: window, name: "Home", screenClass: "Shop.Home")

    #expect(
      observer.reported == [
        .foreground,
        .screen("Home", returning: false),
        .screen("Detail", returning: false),
        .screen("Detail", returning: true),
        .screen("Home", returning: false),
      ]
    )
  }

  @Test("only the screen shown last reports leaving")
  func screenLeaves() {
    let home = Controller()
    let detail = Controller()
    tracker.enterForeground()
    tracker.screenDidAppear(home, layer: window, name: "Home", screenClass: "Shop.Home")
    tracker.screenDidAppear(detail, layer: window, name: "Detail", screenClass: "Shop.Detail")

    tracker.screenDidDisappear(home, isDismissed: false)
    tracker.screenDidDisappear(detail, isDismissed: false)

    #expect(observer.reported.suffix(2) == [.screen("Detail", returning: false), .screenLeft])
  }

  @Test("dismissing a sheet reports the screen left in view beneath it, which UIKit tells nothing")
  func sheetDismissed() {
    let home = Controller()
    let sheet = Controller()
    let filter = Controller()
    let detail = Controller()
    tracker.enterForeground()
    tracker.screenDidAppear(home, layer: window, name: "Home", screenClass: "Shop.Home")
    tracker.screenDidAppear(filter, layer: sheet, name: "Filter", screenClass: "Shop.Filter")

    tracker.screenDidDisappear(filter, isDismissed: false)
    tracker.screenDidAppear(detail, layer: sheet, name: "Detail", screenClass: "Shop.Detail")
    tracker.screenDidDisappear(detail, isDismissed: true)

    #expect(
      observer.reported == [
        .foreground,
        .screen("Home", returning: false),
        .screen("Filter", returning: false),
        .screenLeft,
        .screen("Detail", returning: false),
        .screen("Home", returning: false),
      ]
    )
  }

  @Test("a screen that disappeared under a presentation is not reported when it is dismissed")
  func fullScreenDismissed() {
    let home = Controller()
    let modal = Controller()
    tracker.enterForeground()
    tracker.screenDidAppear(home, layer: window, name: "Home", screenClass: "Shop.Home")
    tracker.screenDidAppear(modal, layer: modal, name: "Modal", screenClass: "Shop.Modal")
    tracker.screenDidDisappear(home, isDismissed: false)

    tracker.screenDidDisappear(modal, isDismissed: true)

    #expect(observer.reported.suffix(2) == [.screen("Modal", returning: false), .screenLeft])
  }

  @Test("a screen that appears before the app comes to the foreground is reported right after it does")
  func pendingScreen() {
    let home = Controller()

    tracker.screenDidAppear(home, layer: window, name: "Home", screenClass: "Shop.Home")
    #expect(observer.reported.isEmpty)
    tracker.enterForeground()

    #expect(observer.reported == [.foreground, .screen("Home", returning: false)])
  }

  @Test("a screen that went before the app came to the foreground is not reported")
  func pendingScreenGone() {
    let home = Controller()
    tracker.screenDidAppear(home, layer: window, name: "Home", screenClass: "Shop.Home")
    tracker.screenDidDisappear(home, isDismissed: false)
    appearAndRelease()

    tracker.enterForeground()

    #expect(observer.reported == [.foreground])
  }

  @Test("a stopped tracker reports nothing, not even a screen it held back")
  func stopped() {
    let home = Controller()
    tracker.screenDidAppear(home, layer: window, name: "Home", screenClass: "Shop.Home")

    tracker.stop()
    tracker.enterForeground()
    tracker.screenDidAppear(home, layer: window, name: "Home", screenClass: "Shop.Home")
    tracker.screenDidDisappear(home, isDismissed: false)
    tracker.enterBackground()

    #expect(observer.reported.isEmpty)
    #expect(tasks.withLock { $0 }.isEmpty)
  }

  private func appearAndRelease() {
    let controller = Controller()
    tracker.screenDidAppear(controller, layer: window, name: "Gone", screenClass: "Shop.Gone")
  }
}
