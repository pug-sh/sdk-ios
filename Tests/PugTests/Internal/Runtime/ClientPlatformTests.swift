import Foundation
import Testing

@testable import Pug

/// The client with a device under it: auto-properties, the app's lifecycle, screens, installs and files.
final class ClientPlatformTests {
  private static let project = "proj_1"
  private static let start: Int64 = 1_760_000_000_000

  /// The worker's clock plus time that passes on the main thread while the worker has not run yet.
  private struct MainThreadClock: Clock {
    let scheduler: TestScheduler
    let elapsed: Locked<Int64>

    var nowMillis: Int64 {
      scheduler.nowMillis + elapsed.withLock { $0 }
    }
  }

  private let root: URL
  private let scheduler: TestScheduler
  private let transport: FakeTransport
  private let logger = RecordingLogger()
  private let storage = Pug.MemoryStorage()
  private let keys = StorageKeys(projectId: ClientPlatformTests.project)
  private let ids = SequentialIds()
  private let elapsed = Locked<Int64>(0)

  init() throws {
    let scheduler = TestScheduler(startMillis: Self.start)
    self.scheduler = scheduler
    transport = FakeTransport { scheduler.currentTime }
    root = FileManager.default.temporaryDirectory.appendingPathComponent("ClientPlatformTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: root)
  }

  @Test("device and app properties ride on every event")
  func autoProperties() throws {
    let platform = FakePlatform(properties: ["$os": "iOS", "$screenWidth": 393])
    let client = try makeClient(platform) { $0.batchMaxSize = 1 }

    client.track("a", properties: nil, options: nil)
    scheduler.runCurrent()

    let auto = try transport.batches.single().single().autoProperties
    #expect(auto["$os"] == .string("iOS"))
    #expect(auto["$screenWidth"] == .int(393))
    #expect(auto["$projectId"] == .string(Self.project))
    #expect(auto["$platform"] == .string("ios"))
    #expect(auto["$url"] == nil)
  }

  @Test("each visit to the foreground opens with app_open and closes with app_close")
  func openAndClose() throws {
    let platform = FakePlatform()
    _ = try makeClient(platform) { $0.batchMaxSize = 1 }
    #expect(platform.observesScreens == true)

    platform.foreground()
    platform.foreground()
    scheduler.runCurrent()
    platform.background()
    scheduler.runCurrent()
    platform.foreground()
    scheduler.runCurrent()

    #expect(transport.kinds.flatMap { $0 } == ["app_open", "app_close", "app_open"])
  }

  @Test("leaving the foreground sends app_close at once, and the queue with it")
  func backgroundSends() throws {
    let platform = FakePlatform()
    let client = try makeClient(platform) { $0.batchMaxWait = 60 }

    platform.foreground()
    client.track("a", properties: nil, options: nil)
    scheduler.runCurrent()
    #expect(transport.batches.isEmpty)
    platform.background()
    scheduler.runCurrent()

    #expect(transport.kinds == [["app_close"], ["app_open", "a"]])
  }

  @Test("leaving the foreground sends the queue without autoOpenCloseEvents, and despite a pending retry")
  func backgroundSendsDuringRetry() throws {
    transport.failNextBatch(.unavailable)
    let platform = FakePlatform()
    let client = try makeClient(platform) {
      $0.autoOpenCloseEvents = false
      $0.batchMaxSize = 1
      $0.batchMaxWait = 60
    }

    platform.foreground()
    client.track("a", properties: nil, options: nil)
    scheduler.runCurrent()
    platform.background()
    scheduler.runCurrent()

    #expect(transport.kinds == [["a"], ["a"]])
  }

  @Test("leaving the foreground settles once its sends do")
  func backgroundSettles() throws {
    let platform = FakePlatform()
    let client = try makeClient(platform)
    let settled = Locked(false)
    transport.hold()

    client.track("a", properties: nil, options: nil)
    platform.background { settled.withLock { $0 = true } }
    scheduler.runCurrent()
    #expect(!settled.withLock { $0 })
    transport.releaseAll()
    scheduler.runCurrent()

    #expect(settled.withLock { $0 })
  }

  @Test("leaving the foreground after destroy settles at once")
  func backgroundAfterDestroySettles() throws {
    let platform = FakePlatform()
    let client = try makeClient(platform)
    let settled = Locked(false)

    client.destroy()
    platform.background { settled.withLock { $0 = true } }

    #expect(settled.withLock { $0 })
  }

  @Test("an app_open that consent dropped leaves no app_close to follow")
  func droppedOpen() throws {
    let platform = FakePlatform()
    let client = try makeClient(platform) { $0.defaultTrackingConsent = .denied }

    platform.foreground()
    platform.background()
    scheduler.runCurrent()
    client.optInTracking()
    platform.foreground()
    platform.background()
    scheduler.runCurrent()

    #expect(transport.kinds == [["app_close"], ["app_open"]])
  }

  @Test("opting in on screen tracks what the launch could not")
  func optInReplays() throws {
    let platform = FakePlatform(appVersion: "1.0")
    let client = try makeClient(platform) {
      $0.defaultTrackingConsent = .denied
      $0.batchMaxSize = 3
    }

    platform.foreground()
    platform.showScreen("Shop.HomeViewController")
    scheduler.runCurrent()
    #expect(transport.batches.isEmpty)
    elapsed.withLock { $0 = 10 }
    client.optInTracking()
    client.optInTracking()
    client.flush()
    elapsed.withLock { $0 = 20 }
    scheduler.runCurrent()

    let events = try transport.batches.single()
    try #require(events.count == 3)
    #expect(events.map(\.kind) == ["app_install", "app_open", "screen_view"])
    #expect(Set(events.map(\.occurTimeMillis)) == [Self.start + 10])
    #expect(events[2].customProperties["screenName"] == .string("HomeViewController"))
    #expect(events[1].autoProperties["$url"] == .string("HomeViewController"))
    #expect(storage.string(forKey: keys.lastVersion) == "1.0")
  }

  @Test("opting out ends the visit, and opting back in opens one for the new identity")
  func optOutEndsVisit() throws {
    let platform = FakePlatform()
    let client = try makeClient(platform) { $0.batchMaxSize = 1 }

    platform.foreground()
    scheduler.runCurrent()
    client.optOutTracking()
    client.optInTracking()
    platform.background()
    scheduler.runCurrent()

    let events = try transport.batches.map { try $0.single() }
    try #require(events.count == 3)
    #expect(events.map(\.kind) == ["app_open", "app_open", "app_close"])
    #expect(events[0].distinctId != events[1].distinctId)
    #expect(events[1].distinctId == events[2].distinctId)
  }

  @Test("view controllers that appear are screens, named by $url and $referrer on what follows")
  func screens() throws {
    let platform = FakePlatform()
    let client = try makeClient(platform) { $0.batchMaxSize = 1 }

    platform.showScreen("Shop.HomeViewController")
    platform.showScreen("Shop.DetailViewController")
    client.track("tap", properties: nil, options: nil)
    scheduler.runCurrent()

    let events = try transport.batches.map { try $0.single() }
    try #require(events.count == 3)
    #expect(
      events[0].customProperties == [
        "screenName": .string("HomeViewController"),
        "screenClass": .string("Shop.HomeViewController"),
      ]
    )
    #expect(events[0].autoProperties["$url"] == .string("HomeViewController"))
    #expect(events[0].autoProperties["$referrer"] == nil)
    #expect(events[1].kind == "screen_view")
    for event in events[1...] {
      #expect(event.autoProperties["$url"] == .string("DetailViewController"))
      #expect(event.autoProperties["$referrer"] == .string("HomeViewController"))
    }
  }

  @Test("the current screen shown again is not tracked again")
  func sameScreen() throws {
    let platform = FakePlatform()
    let client = try makeClient(platform) { $0.batchMaxSize = 1 }

    platform.showScreen("Shop.HomeViewController")
    platform.showScreen("Shop.HomeViewController")
    client.screen("HomeViewController")
    scheduler.runCurrent()

    #expect(transport.kinds == [["screen_view"]])
  }

  @Test("a view controller back with no screen in between is the same screen, and keeps the name screen gave it")
  func returningScreen() throws {
    let platform = FakePlatform()
    let client = try makeClient(platform) { $0.batchMaxSize = 1 }

    platform.showScreen("Shop.HomeViewController")
    client.screen("Home")
    // Covered by a full-screen controller that is not a screen, such as a photo picker.
    platform.hideScreen()
    platform.showScreen("Shop.HomeViewController", returning: true)
    client.track("tap", properties: nil, options: nil)
    scheduler.runCurrent()

    #expect(transport.kinds.flatMap { $0 } == ["screen_view", "screen_view", "tap"])
    let tap = try #require(try transport.batches.last?.single())
    #expect(tap.autoProperties["$url"] == .string("Home"))
    #expect(tap.autoProperties["$referrer"] == .string("HomeViewController"))
  }

  @Test("a view controller back after another screen became current is a screen again")
  func returningAfterAnotherScreen() throws {
    let platform = FakePlatform()
    let client = try makeClient(platform) { $0.batchMaxSize = 1 }

    platform.showScreen("Shop.HomeViewController")
    platform.hideScreen()
    // A SwiftUI screen over it, named by the app.
    client.screen("Paywall")
    platform.showScreen("Shop.HomeViewController", returning: true)
    scheduler.runCurrent()

    let names = try transport.batches.map { try $0.single().customProperties["screenName"] }
    #expect(names == [.string("HomeViewController"), .string("Paywall"), .string("HomeViewController")])
    #expect(try transport.batches.last?.single().autoProperties["$referrer"] == .string("Paywall"))
  }

  @Test("a view controller that appears again without having gone, as when a swipe back is cancelled, is no new screen")
  func returningWithoutLeaving() throws {
    let platform = FakePlatform()
    let client = try makeClient(platform) { $0.batchMaxSize = 1 }

    platform.showScreen("Shop.DetailViewController")
    client.screen("Item 42")
    platform.showScreen("Shop.DetailViewController", returning: true)
    client.track("tap", properties: nil, options: nil)
    scheduler.runCurrent()

    #expect(transport.kinds.flatMap { $0 } == ["screen_view", "screen_view", "tap"])
    #expect(try transport.batches.last?.single().autoProperties["$url"] == .string("Item 42"))
  }

  @Test("screen names screens of its own")
  func namedScreen() throws {
    let client = try makeClient { $0.batchMaxSize = 1 }

    client.screen("Settings")
    scheduler.runCurrent()

    let event = try transport.batches.single().single()
    #expect(event.kind == "screen_view")
    #expect(event.customProperties == ["screenName": .string("Settings")])
    #expect(event.autoProperties["$url"] == .string("Settings"))
  }

  @Test("with autoScreenViews off, view controllers leave the screen to screen()")
  func autoScreenViewsOff() throws {
    let platform = FakePlatform()
    let client = try makeClient(platform) {
      $0.autoScreenViews = false
      $0.batchMaxSize = 1
    }

    client.screen("Feed")
    platform.showScreen("Shop.MainViewController")
    platform.hideScreen()
    client.track("tap", properties: nil, options: nil)
    scheduler.runCurrent()

    #expect(platform.observesScreens == false)
    #expect(transport.kinds.flatMap { $0 } == ["screen_view", "tap"])
    #expect(try transport.batches.last?.single().autoProperties["$url"] == .string("Feed"))
  }

  @Test("a blank screen name is dropped and a long one cut short")
  func screenNames() throws {
    let client = try makeClient { $0.batchMaxSize = 1 }

    client.screen(" ")
    client.screen(String(repeating: "é", count: 600))
    scheduler.runCurrent()

    let event = try transport.batches.single().single()
    #expect(event.customProperties["screenName"] == .string(String(repeating: "é", count: 512)))
    #expect(event.autoProperties["$url"] == .string(String(repeating: "é", count: 512)))
    #expect(
      logger.warnings == ["A screen with a blank name was dropped", "A screen name was truncated to 1024 bytes"]
    )
  }

  @Test("the first launch tracks app_install, dated at initialize and before the launch's app_open")
  func install() throws {
    let platform = FakePlatform(appVersion: "1.0")
    _ = try makeClient(platform) { $0.batchMaxSize = 2 }

    elapsed.withLock { $0 = 10 }
    platform.foreground()
    elapsed.withLock { $0 = 20 }
    scheduler.runCurrent()

    let events = try transport.batches.single()
    try #require(events.count == 2)
    #expect(events[0].kind == "app_install")
    #expect(events[0].occurTimeMillis == Self.start)
    #expect(events[0].customProperties == ["appVersion": .string("1.0")])
    #expect(events[1].kind == "app_open")
    #expect(events[1].occurTimeMillis == Self.start + 10)
    #expect(storage.string(forKey: keys.lastVersion) == "1.0")
  }

  @Test("app_install names where the app came from")
  func installSource() throws {
    _ = try makeClient(FakePlatform(appVersion: "1.0", installSource: "com.apple")) { $0.batchMaxSize = 1 }

    scheduler.runCurrent()

    #expect(
      try transport.batches.single().single().customProperties == [
        "appVersion": .string("1.0"), "installSource": .string("com.apple"),
      ]
    )
  }

  @Test("a new app version tracks app_update, without reading the install source")
  func update() throws {
    storage.setString("1.0", forKey: keys.lastVersion)
    let platform = FakePlatform(appVersion: "1.1", installSource: "com.apple")
    _ = try makeClient(platform) { $0.batchMaxSize = 1 }

    scheduler.runCurrent()

    let update = try transport.batches.single().single()
    #expect(update.kind == "app_update")
    #expect(update.customProperties == ["appVersion": .string("1.1"), "previousVersion": .string("1.0")])
    #expect(platform.installSourceReads == 0)
    #expect(logger.warnings.isEmpty)
  }

  @Test("a stored choice that cannot be read skips install detection, even once the user opts in")
  func unreadableConsentSkipsInstall() throws {
    struct Unreadable: Error {}
    let client = try makeClient(FakePlatform(appVersion: "1.0")) {
      $0.storage = ThrowingStorage(Unreadable())
      $0.batchMaxSize = 1
    }

    client.optInTracking()
    client.track("a", properties: nil, options: nil)
    scheduler.runCurrent()

    #expect(transport.kinds == [["a"]])
    #expect(logger.debugs.contains("app_install and app_update are not tracked: storage could not be read"))
  }

  @Test("with autoInstallEvents off neither is tracked")
  func autoInstallEventsOff() throws {
    _ = try makeClient(FakePlatform(appVersion: "1.0")) {
      $0.autoInstallEvents = false
      $0.batchMaxSize = 1
    }

    scheduler.runCurrent()

    #expect(transport.batches.isEmpty)
    #expect(storage.string(forKey: keys.lastVersion) == nil)
  }

  @Test("an app extension, which has a container of its own, tracks no install")
  func appExtension() throws {
    _ = try makeClient(FakePlatform(appVersion: "1.0", appExtension: true)) { $0.batchMaxSize = 1 }

    scheduler.runCurrent()

    #expect(transport.batches.isEmpty)
    #expect(storage.string(forKey: keys.lastVersion) == nil)
    #expect(logger.debugs.contains("app_install and app_update are not tracked in an app extension"))
  }

  @Test("an initialize after destroy does not track the install again")
  func installOnce() throws {
    let first = try makeClient(FakePlatform(appVersion: "1.0")) { $0.batchMaxSize = 1 }
    scheduler.runCurrent()
    first.destroy()
    scheduler.runCurrent()

    let second = try makeClient(FakePlatform(appVersion: "1.0"), after: first.teardown) { $0.batchMaxSize = 1 }
    second.track("a", properties: nil, options: nil)
    scheduler.runCurrent()

    #expect(transport.kinds == [["app_install"], ["a"]])
  }

  @Test("the default storage writes to the platform's directory after a pause")
  func defaultStorage() throws {
    let directory = root.appendingPathComponent("pug")
    let client = try makeClient(FakePlatform(directory: directory)) {
      $0.storage = nil
      $0.batchMaxWait = 60
    }

    client.track("a", properties: nil, options: nil)
    scheduler.runCurrent()
    #expect(try storedKinds(directory).isEmpty)
    scheduler.advanceTime(by: FileStorage.syncDelayMillis)
    scheduler.runCurrent()

    #expect(try storedKinds(directory) == ["a"])
  }

  @Test("an opt-out reaches the disk at once")
  func optOutReachesDisk() throws {
    let directory = root.appendingPathComponent("pug")
    let client = try makeClient(FakePlatform(directory: directory)) {
      $0.storage = nil
      $0.batchMaxWait = 60
    }
    client.track("a", properties: nil, options: nil)
    scheduler.advanceTime(by: FileStorage.syncDelayMillis)
    scheduler.runCurrent()
    #expect(try storedKinds(directory) == ["a"])

    client.optOutTracking()
    scheduler.runCurrent()

    #expect(try storedKinds(directory).isEmpty)
    let consent = directory.appendingPathComponent(FileStorage.fileName(keys.consent))
    #expect(try String(contentsOf: consent, encoding: .utf8) == "denied")
  }

  @Test("leaving the foreground writes storage at once, and again once the sends settle")
  func backgroundWrites() throws {
    let directory = root.appendingPathComponent("pug")
    let platform = FakePlatform(directory: directory)
    let client = try makeClient(platform) {
      $0.storage = nil
      $0.autoOpenCloseEvents = false
    }
    transport.hold()

    client.track("a", properties: nil, options: nil)
    scheduler.runCurrent()
    platform.background()
    scheduler.runCurrent()
    #expect(try storedKinds(directory) == ["a"])
    transport.releaseAll()
    scheduler.runCurrent()

    #expect(try storedKinds(directory).isEmpty)
  }

  @Test("destroy writes storage before the next client reads it")
  func destroyWrites() throws {
    let directory = root.appendingPathComponent("pug")
    transport.batchFailure = .unavailable
    let first = try makeClient(FakePlatform(directory: directory)) { $0.storage = nil }
    first.track("a", properties: nil, options: nil)
    first.destroy()
    scheduler.runCurrent()
    transport.batchFailure = nil

    let second = try makeClient(FakePlatform(directory: directory), after: first.teardown) { $0.storage = nil }
    second.flush()
    scheduler.runCurrent()

    #expect(transport.kinds == [["a"], ["a"]])
  }

  @Test("without a storage directory state stays in memory")
  func noStorageDirectory() throws {
    let client = try makeClient(FakePlatform(directory: nil)) {
      $0.storage = nil
      $0.batchMaxSize = 1
    }

    client.track("a", properties: nil, options: nil)
    scheduler.runCurrent()

    #expect(transport.kinds == [["a"]])
    #expect(logger.warnings == ["No storage directory is available; state is kept in memory until the app restarts"])
  }

  @Test("files that cannot be read before the first unlock are waited for, and the calls made meanwhile with them")
  func waitsForUnlock() throws {
    let directory = root.appendingPathComponent("pug")
    let previous = try storeQueuedEvent(in: directory)
    let queue = directory.appendingPathComponent(FileStorage.fileName(keys.queue))
    let unreadable = try makeUnreadable(queue)
    let platform = FakePlatform(directory: directory, locked: true)
    let client = try makeClient(platform, after: previous.teardown) {
      $0.storage = nil
      $0.batchMaxSize = 2
    }

    client.track("b", properties: nil, options: nil)
    scheduler.runCurrent()
    #expect(platform.isWaitingForProtectedData)
    #expect(transport.batches.count == 1)
    try unreadable.restore()
    platform.unlock()
    scheduler.runCurrent()

    let events = try #require(transport.batches.last)
    #expect(events.map(\.kind) == ["a", "b"])
    #expect(Set(events.map(\.distinctId)).count == 1)
    #expect(client.trackingConsent == .granted)
    #expect(!logger.warnings.contains { $0.hasPrefix("Storage failed") })
  }

  @Test("files still unreadable once the device is unlocked move the client to memory")
  func unreadableAfterUnlock() throws {
    let directory = root.appendingPathComponent("pug")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    _ = try makeUnreadable(directory.appendingPathComponent(FileStorage.fileName(keys.queue)))
    let platform = FakePlatform(directory: directory, locked: true)
    let client = try makeClient(platform) {
      $0.storage = nil
      $0.batchMaxSize = 1
    }

    client.track("b", properties: nil, options: nil)
    scheduler.runCurrent()
    platform.unlock()
    scheduler.runCurrent()

    #expect(transport.kinds == [["b"]])
    #expect(logger.warnings == ["Storage failed; state is kept in memory only until the app restarts"])
  }

  @Test("a destroy while start waits for the unlock finishes after it")
  func destroyWhileLocked() throws {
    let directory = root.appendingPathComponent("pug")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let unreadable = try makeUnreadable(directory.appendingPathComponent(FileStorage.fileName(keys.queue)))
    let platform = FakePlatform(directory: directory, locked: true)
    let client = try makeClient(platform) { $0.storage = nil }

    client.destroy()
    scheduler.runCurrent()
    #expect(!client.teardown.isFinished)
    try unreadable.restore()
    platform.unlock()
    scheduler.runCurrent()

    #expect(client.teardown.isFinished)
  }

  @Test("destroy stops observing the lifecycle, and later callbacks are ignored")
  func destroyStopsObserving() throws {
    let platform = FakePlatform()
    let client = try makeClient(platform)
    #expect(platform.isObserving)

    client.destroy()
    platform.foreground()
    scheduler.runCurrent()

    #expect(!platform.isObserving)
    #expect(transport.batches.isEmpty)
    #expect(logger.debugs.contains("Tracking the app moving to the foreground was ignored: Pug was destroyed"))
  }

  @Test("a destroy that comes before start still stops the observation start makes")
  func destroyBeforeStart() throws {
    let platform = FakePlatform()
    let client = try makeClient(platform, starts: false)

    client.destroy()
    client.start(after: nil)
    scheduler.runCurrent()

    #expect(!platform.isObserving)
    #expect(client.teardown.isFinished)
  }

  @Test("a platform without a lifecycle to observe is reported at debug level")
  func unobservable() throws {
    _ = try makeClient(FakePlatform(observable: false))

    #expect(
      logger.debugs == ["App open, close and screen events are not tracked: there is no app lifecycle to observe"]
    )
    #expect(logger.warnings.isEmpty)
  }

  private func makeClient(
    _ platform: FakePlatform = FakePlatform(),
    after previous: Teardown? = nil,
    starts: Bool = true,
    _ configure: (inout Pug.Options) -> Void = { _ in }
  ) throws -> Client {
    var options = Pug.Options(apiKey: "pub_key")
    options.logger = logger
    options.storage = storage
    options.debug = true
    configure(&options)
    let client = Client(
      configuration: try Configuration(projectId: Self.project, options: options),
      transport: transport,
      scheduler: scheduler,
      clock: MainThreadClock(scheduler: scheduler, elapsed: elapsed),
      platform: platform,
      ids: ids,
      random: { 0.5 }
    )
    if starts {
      client.start(after: previous)
    }
    return client
  }

  /// Leaves an undelivered event "a" in `directory`, as an earlier launch would, and returns its client.
  private func storeQueuedEvent(in directory: URL) throws -> Client {
    transport.batchFailure = .unavailable
    let client = try makeClient(FakePlatform(directory: directory)) { $0.storage = nil }
    client.track("a", properties: nil, options: nil)
    client.destroy()
    scheduler.runCurrent()
    transport.batchFailure = nil
    return client
  }

  /// Puts a directory where `file` is, which reads fail on as they do on a protected file, until `restore()`.
  private func makeUnreadable(_ file: URL) throws -> UnreadableFile {
    let fileManager = FileManager.default
    let aside = file.appendingPathExtension("aside")
    if fileManager.fileExists(atPath: file.path) {
      try fileManager.moveItem(at: file, to: aside)
    }
    try fileManager.createDirectory(at: file, withIntermediateDirectories: true)
    return UnreadableFile(file: file, aside: aside)
  }

  private func storedKinds(_ directory: URL) throws -> [String] {
    let file = directory.appendingPathComponent(FileStorage.fileName(keys.queue))
    guard FileManager.default.fileExists(atPath: file.path) else { return [] }
    let array = try #require(StoredJSON.parse(try String(contentsOf: file, encoding: .utf8)) as? [Any])
    return try array.map { try #require(EventJSON.decode($0)).kind }
  }
}

private struct UnreadableFile {
  let file: URL
  let aside: URL

  func restore() throws {
    let fileManager = FileManager.default
    try fileManager.removeItem(at: file)
    if fileManager.fileExists(atPath: aside.path) {
      try fileManager.moveItem(at: aside, to: file)
    }
  }
}
