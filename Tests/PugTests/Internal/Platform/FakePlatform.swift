import Foundation
import Testing

@testable import Pug

/// A fixed device whose lifecycle the test drives, as the main thread would.
final class FakePlatform: Platform {
  private struct State: Sendable {
    var observer: (any LifecycleObserver)?
    var isObserving = false
    var observesScreens: Bool?
    var mainThread: [@MainActor @Sendable () -> Void] = []
    var installSourceReads = 0
    var isProtectedDataAvailable: Bool
    var protectedDataWaiters: [@Sendable () -> Void] = []
    var deviceRefreshes = 0
  }

  private struct FixedProperties: AutoProperties {
    let appVersion: String?
    let values: [String: any Sendable]

    func current() -> [String: Any] {
      values
    }
  }

  private final class Observation: Cancellable {
    private let platform: FakePlatform

    init(_ platform: FakePlatform) {
      self.platform = platform
    }

    func cancel() {
      platform.state.withLock { $0.isObserving = false }
    }
  }

  private let directory: URL?
  private let properties: [String: any Sendable]
  private let appVersion: String?
  private let source: String?
  private let isObservable: Bool
  private let runsMainAtOnce: Bool
  private let state: Locked<State>
  let isAppExtension: Bool

  /// `runsMainAtOnce` runs main-thread work as it is posted, for tests on the main actor. `locked` keeps protected
  /// data unavailable until `unlock()`.
  init(
    directory: URL? = nil,
    properties: [String: any Sendable] = [:],
    appVersion: String? = nil,
    installSource: String? = nil,
    observable: Bool = true,
    runsMainAtOnce: Bool = false,
    appExtension: Bool = false,
    locked: Bool = false
  ) {
    self.directory = directory
    self.properties = properties
    self.appVersion = appVersion
    source = installSource
    isObservable = observable
    self.runsMainAtOnce = runsMainAtOnce
    isAppExtension = appExtension
    state = Locked(State(isProtectedDataAvailable: !locked))
  }

  var isObserving: Bool {
    state.withLock { $0.isObserving }
  }

  /// Whether the client asked for view controllers, nil until it observes.
  var observesScreens: Bool? {
    state.withLock { $0.observesScreens }
  }

  var isWaitingForProtectedData: Bool {
    state.withLock { !$0.protectedDataWaiters.isEmpty }
  }

  var installSourceReads: Int {
    state.withLock { $0.installSourceReads }
  }

  var deviceRefreshes: Int {
    state.withLock { $0.deviceRefreshes }
  }

  func storageDirectory() -> URL? {
    directory
  }

  func whenProtectedDataAvailable(logger: SafeLogger, _ work: @escaping @Sendable () -> Void) {
    let isAvailable = state.withLock { state in
      if !state.isProtectedDataAvailable {
        state.protectedDataWaiters.append(work)
      }
      return state.isProtectedDataAvailable
    }
    if isAvailable {
      work()
    }
  }

  func autoProperties(logger: SafeLogger) -> any AutoProperties {
    FixedProperties(appVersion: appVersion, values: properties)
  }

  func installSource() -> String? {
    state.withLock { $0.installSourceReads += 1 }
    return source
  }

  func observeLifecycle(_ observer: any LifecycleObserver, screens: Bool, logger: SafeLogger) -> (any Cancellable)? {
    guard isObservable else { return nil }
    state.withLock { state in
      state.observer = observer
      state.isObserving = true
      state.observesScreens = screens
    }
    return Observation(self)
  }

  func runOnMain(_ work: @escaping @MainActor @Sendable () -> Void) {
    if runsMainAtOnce {
      MainActor.assumeIsolated(work)
    } else {
      state.withLock { $0.mainThread.append(work) }
    }
  }

  func refreshDevice() {
    state.withLock { $0.deviceRefreshes += 1 }
  }

  /// Runs what was posted to the main thread so far, as its run loop would.
  @MainActor
  func runMainThread() {
    while let work = state.withLock({ $0.mainThread.isEmpty ? nil : $0.mainThread.removeFirst() }) {
      work()
    }
  }

  func foreground() {
    observer()?.appDidEnterForeground()
  }

  func background(then settled: @escaping @Sendable () -> Void = {}) {
    observer()?.appDidEnterBackground(then: settled)
  }

  /// A view controller of `screenClass`, module-qualified as `NSStringFromClass` names it, appears: `returning` when
  /// it is the one that appeared last. As on a device, only reported when the client asked for view controllers.
  func showScreen(_ screenClass: String, returning: Bool = false) {
    guard let observer = observer(), observesScreens == true else { return }
    let name = screenClass.split(separator: ".").last.map(String.init) ?? screenClass
    observer.screenDidAppear(name: name, screenClass: screenClass, isReturning: returning)
  }

  /// A SwiftUI view that `pugScreen(_:)` names appears, reported whether or not the client asked for view controllers.
  func showNamedScreen(_ name: String, returning: Bool = false) {
    observer()?.screenDidAppear(name: name, screenClass: nil, isReturning: returning)
  }

  /// The screen that appeared last disappears.
  func hideScreen() {
    observer()?.screenDidDisappear()
  }

  /// The device is unlocked: protected data becomes available.
  func unlock() {
    let waiters = state.withLock { state in
      defer { state.protectedDataWaiters = [] }
      state.isProtectedDataAvailable = true
      return state.protectedDataWaiters
    }
    for waiter in waiters {
      waiter()
    }
  }

  private func observer() -> (any LifecycleObserver)? {
    let observer = state.withLock { $0.observer }
    if observer == nil {
      Issue.record("the client is not observing the lifecycle")
    }
    return observer
  }
}
