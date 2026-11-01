import Foundation
import Testing

@testable import Pug

/// A fixed device whose lifecycle the test drives, as the main thread would.
final class FakePlatform: Platform {
  private struct State: Sendable {
    var observer: (any LifecycleObserver)?
    var isObserving = false
    var mainThread: [@MainActor @Sendable () -> Void] = []
    var installSourceReads = 0
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
  private let state = Locked(State())

  /// `runsMainAtOnce` runs main-thread work as it is posted, for tests on the main actor.
  init(
    directory: URL? = nil,
    properties: [String: any Sendable] = [:],
    appVersion: String? = nil,
    installSource: String? = nil,
    observable: Bool = true,
    runsMainAtOnce: Bool = false
  ) {
    self.directory = directory
    self.properties = properties
    self.appVersion = appVersion
    source = installSource
    isObservable = observable
    self.runsMainAtOnce = runsMainAtOnce
  }

  var isObserving: Bool {
    state.withLock { $0.isObserving }
  }

  var installSourceReads: Int {
    state.withLock { $0.installSourceReads }
  }

  func storageDirectory() -> URL? {
    directory
  }

  func autoProperties(logger: SafeLogger) -> any AutoProperties {
    FixedProperties(appVersion: appVersion, values: properties)
  }

  func installSource() -> String? {
    state.withLock { $0.installSourceReads += 1 }
    return source
  }

  func observeLifecycle(_ observer: any LifecycleObserver, logger: SafeLogger) -> (any Cancellable)? {
    guard isObservable else { return nil }
    state.withLock { state in
      state.observer = observer
      state.isObserving = true
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

  /// A view controller of `screenClass`, module-qualified as `NSStringFromClass` names it, appears.
  func showScreen(_ screenClass: String) {
    let name = screenClass.split(separator: ".").last.map(String.init) ?? screenClass
    observer()?.screenDidAppear(name: name, screenClass: screenClass)
  }

  private func observer() -> (any LifecycleObserver)? {
    let observer = state.withLock { $0.observer }
    if observer == nil {
      Issue.record("the client is not observing the lifecycle")
    }
    return observer
  }
}
