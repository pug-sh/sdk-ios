import Testing

@testable import Pug

@MainActor
struct AppLifecycleTrackerTests {
  /// Stands in for a view controller.
  private final class Controller {}

  private let observer = RecordingLifecycleObserver()
  private let tasks = Locked<[String]>([])
  private let tracker: AppLifecycleTracker

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

    tracker.screenDidAppear(home, name: "Home", screenClass: "Shop.Home")
    tracker.screenDidAppear(detail, name: "Detail", screenClass: "Shop.Detail")
    tracker.screenDidAppear(detail, name: "Detail", screenClass: "Shop.Detail")
    tracker.screenDidAppear(home, name: "Home", screenClass: "Shop.Home")

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
    tracker.screenDidAppear(home, name: "Home", screenClass: "Shop.Home")
    tracker.screenDidAppear(detail, name: "Detail", screenClass: "Shop.Detail")

    tracker.screenDidDisappear(home)
    tracker.screenDidDisappear(detail)

    #expect(observer.reported.suffix(2) == [.screen("Detail", returning: false), .screenLeft])
  }

  @Test("a screen that appears before the app comes to the foreground is reported right after it does")
  func pendingScreen() {
    let home = Controller()

    tracker.screenDidAppear(home, name: "Home", screenClass: "Shop.Home")
    #expect(observer.reported.isEmpty)
    tracker.enterForeground()

    #expect(observer.reported == [.foreground, .screen("Home", returning: false)])
  }

  @Test("a screen that went before the app came to the foreground is not reported")
  func pendingScreenGone() {
    let home = Controller()
    tracker.screenDidAppear(home, name: "Home", screenClass: "Shop.Home")
    tracker.screenDidDisappear(home)
    appearAndRelease()

    tracker.enterForeground()

    #expect(observer.reported == [.foreground])
  }

  @Test("a stopped tracker reports nothing, not even a screen it held back")
  func stopped() {
    let home = Controller()
    tracker.screenDidAppear(home, name: "Home", screenClass: "Shop.Home")

    tracker.stop()
    tracker.enterForeground()
    tracker.screenDidAppear(home, name: "Home", screenClass: "Shop.Home")
    tracker.screenDidDisappear(home)
    tracker.enterBackground()

    #expect(observer.reported.isEmpty)
    #expect(tasks.withLock { $0 }.isEmpty)
  }

  private func appearAndRelease() {
    let controller = Controller()
    tracker.screenDidAppear(controller, name: "Gone", screenClass: "Shop.Gone")
  }
}
