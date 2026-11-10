import Testing

@testable import Pug

struct InstallTrackerTests {
  private struct Captured: Equatable {
    let kind: String
    let properties: [String: String]
  }

  private struct Failure: Error {}

  /// `base`, except that reads of `key` fail.
  private struct FailingKey: Pug.Storage {
    let base: Pug.MemoryStorage
    let key: String

    func string(forKey key: String) throws -> String? {
      guard key != self.key else { throw Failure() }
      return base.string(forKey: key)
    }

    func setString(_ value: String, forKey key: String) {
      base.setString(value, forKey: key)
    }

    func removeValue(forKey key: String) {
      base.removeValue(forKey: key)
    }
  }

  private let memory = Pug.MemoryStorage()
  private let keys = StorageKeys(projectId: "proj_1")
  private let logger = RecordingLogger()
  private let captured = Locked<[Captured]>([])

  @Test("the first launch is an install, with its source")
  func install() {
    let tracker = makeTracker()

    tracker.check(appVersion: "1.0") { "com.apple" }
    tracker.emit(capture)

    #expect(
      captured.withLock { $0 } == [
        Captured(kind: "app_install", properties: ["appVersion": "1.0", "installSource": "com.apple"])
      ]
    )
    #expect(memory.string(forKey: keys.lastVersion) == "1.0")
  }

  @Test("a new version is an update from the last one")
  func update() {
    memory.setString("1.0", forKey: keys.lastVersion)
    let tracker = makeTracker()

    tracker.check(appVersion: "1.1", installSource: unread)
    tracker.emit(capture)

    #expect(
      captured.withLock { $0 } == [
        Captured(kind: "app_update", properties: ["appVersion": "1.1", "previousVersion": "1.0"])
      ]
    )
    #expect(memory.string(forKey: keys.lastVersion) == "1.1")
  }

  @Test("the same version tracks nothing")
  func sameVersion() {
    memory.setString("1.0", forKey: keys.lastVersion)
    let tracker = makeTracker()

    tracker.check(appVersion: "1.0", installSource: unread)
    tracker.emit(capture)

    #expect(captured.withLock { $0 }.isEmpty)
  }

  @Test("an app that used Pug before recording versions is not a new install")
  func earlierActivity() {
    memory.setString(#"{"anonymousId":"anon-1"}"#, forKey: keys.profile)
    let tracker = makeTracker()

    tracker.check(appVersion: "1.0", installSource: unread)
    tracker.emit(capture)

    #expect(captured.withLock { $0 }.isEmpty)
    #expect(memory.string(forKey: keys.lastVersion) == "1.0")
  }

  @Test("a stored consent choice is not earlier activity")
  func consentIsNotActivity() {
    memory.setString("granted", forKey: keys.consent)
    memory.setString("", forKey: keys.lastVersion)
    let tracker = makeTracker()

    tracker.check(appVersion: "1.0") { nil }
    tracker.emit(capture)

    #expect(captured.withLock { $0 } == [Captured(kind: "app_install", properties: ["appVersion": "1.0"])])
  }

  @Test("an event consent kept back waits for the next emit")
  func heldBack() {
    let tracker = makeTracker()
    tracker.check(appVersion: "1.0") { nil }

    tracker.emit { _, _ in false }
    #expect(memory.string(forKey: keys.lastVersion) == nil)
    tracker.emit(capture)
    tracker.emit(capture)

    #expect(captured.withLock { $0 }.map(\.kind) == ["app_install"])
    #expect(memory.string(forKey: keys.lastVersion) == "1.0")
  }

  @Test("without an app version nothing is tracked")
  func noAppVersion() {
    let tracker = makeTracker()

    tracker.check(appVersion: nil, installSource: unread)
    tracker.check(appVersion: "", installSource: unread)
    tracker.emit(capture)

    #expect(captured.withLock { $0 }.isEmpty)
    #expect(memory.string(forKey: keys.lastVersion) == nil)
    #expect(
      logger.debugs
        == Array(
          repeating: "app_install and app_update are not tracked: the app version could not be read",
          count: 2
        )
    )
  }

  @Test("storage that could not be read tracks no install, since every launch would look like one")
  func failedStorage() {
    let tracker = InstallTracker(
      storage: SafeStorage(ThrowingStorage(Failure()), logger: logger.safe()),
      keys: keys,
      logger: logger.safe()
    )

    tracker.check(appVersion: "1.0", installSource: unread)
    tracker.emit(capture)

    #expect(captured.withLock { $0 }.isEmpty)
    #expect(logger.debugs == ["app_install and app_update are not tracked: storage could not be read"])
  }

  @Test("a read that fails after the check tracks nothing, since memory would not keep the version")
  func failureAfterCheck() {
    memory.setString("1.0", forKey: keys.lastVersion)
    let storage = SafeStorage(FailingKey(base: memory, key: keys.queue), logger: logger.safe())
    let tracker = InstallTracker(storage: storage, keys: keys, logger: logger.safe())

    tracker.check(appVersion: "1.1", installSource: unread)
    _ = storage.string(forKey: keys.queue)
    tracker.emit(capture)

    #expect(captured.withLock { $0 }.isEmpty)
    #expect(memory.string(forKey: keys.lastVersion) == "1.0")
  }

  private func makeTracker() -> InstallTracker {
    InstallTracker(storage: SafeStorage(memory, logger: logger.safe()), keys: keys, logger: logger.safe())
  }

  private func unread() -> String? {
    Issue.record("the install source was read")
    return nil
  }

  private func capture(_ kind: String, _ properties: [String: String]) -> Bool {
    captured.withLock { $0.append(Captured(kind: kind, properties: properties)) }
    return true
  }
}
