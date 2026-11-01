import Testing

@testable import Pug

struct TrackingConsentControllerTests {
  private final class RecordingPurge: ConsentPurge {
    var calls: [String] = []
    var isIdentified = false

    func dropQueue() {
      calls.append("dropQueue")
    }

    func forgetIdentity() {
      calls.append("forgetIdentity")
    }
  }

  private static let key = "__pug_proj_1_consent__"

  private let memory = Pug.MemoryStorage()
  private let logger = RecordingLogger()
  private let purge = RecordingPurge()

  @Test("consent is granted and pending by default")
  func defaults() {
    let consent = makeController()

    #expect(consent.consent == .granted)
    #expect(consent.isGranted)
    #expect(consent.isPending)
  }

  @Test("opting out drops the queue and forgets the identity")
  func optOut() {
    let consent = makeController()

    consent.set(.denied, purging: purge)

    #expect(consent.consent == .denied)
    #expect(!consent.isGranted)
    #expect(!consent.isPending)
    #expect(purge.calls == ["dropQueue", "forgetIdentity"])
  }

  @Test("opting in purges nothing")
  func optIn() {
    let consent = makeController(default: .denied)

    consent.set(.granted, purging: purge)

    #expect(consent.isGranted)
    #expect(!consent.isPending)
    #expect(purge.calls.isEmpty)
  }

  @Test("choices are only written when persisted")
  func persistence() {
    makeController(persists: false).set(.denied, purging: purge)
    #expect(memory.string(forKey: Self.key) == nil)

    let persisted = makeController(persists: true)
    persisted.set(.denied, purging: purge)
    #expect(memory.string(forKey: Self.key) == "denied")
    persisted.set(.granted, purging: purge)
    #expect(memory.string(forKey: Self.key) == "granted")
  }

  @Test("a persisted choice outranks the default and is no longer pending")
  func storedChoice() {
    memory.setString("granted", forKey: Self.key)

    let consent = makeController(default: .denied, persists: true)

    #expect(consent.consent == .granted)
    #expect(!consent.isPending)
  }

  @Test("a stored choice is ignored without persistence")
  func storedChoiceIgnored() {
    memory.setString("denied", forKey: Self.key)

    let consent = makeController(persists: false)

    #expect(consent.consent == .granted)
    #expect(consent.isPending)
  }

  @Test("an invalid stored choice is ignored with a warning")
  func invalidStoredChoice() {
    memory.setString("Denied", forKey: Self.key)

    let consent = makeController(default: .denied, persists: true)

    #expect(consent.consent == .denied)
    #expect(consent.isPending)
    #expect(logger.warnings == [#"The stored tracking consent "Denied" is not valid and was ignored"#])
  }

  @Test("a stored denial purges identity and queue at init")
  func storedDenialAtInit() {
    memory.setString("denied", forKey: Self.key)
    let consent = makeController(persists: true)

    consent.enforceAtInit(purging: purge)

    #expect(purge.calls == ["dropQueue", "forgetIdentity"])
  }

  @Test("a default denial drops only the queue at init")
  func defaultDenialAtInit() {
    let consent = makeController(default: .denied, persists: true)

    consent.enforceAtInit(purging: purge)

    #expect(purge.calls == ["dropQueue"])
    #expect(logger.warnings.isEmpty)
  }

  @Test("a default denial over an identified user warns that the id is kept")
  func defaultDenialOverIdentifiedUser() {
    purge.isIdentified = true
    let consent = makeController(default: .denied)

    consent.enforceAtInit(purging: purge)

    #expect(purge.calls == ["dropQueue"])
    #expect(logger.warnings.count == 1)
    #expect(
      logger.warnings.first?.hasPrefix("Tracking consent is denied by default, but an external id") == true
    )
  }

  @Test("granted consent changes nothing at init")
  func grantedAtInit() {
    memory.setString("granted", forKey: Self.key)

    makeController(persists: true).enforceAtInit(purging: purge)
    makeController(persists: false).enforceAtInit(purging: purge)

    #expect(purge.calls.isEmpty)
  }

  @Test("a stored choice that cannot be read is denied until the user chooses, as it may be an opt-out")
  func unreadableChoice() {
    struct Unreadable: Error {}
    let consent = TrackingConsentController(
      storage: SafeStorage(ThrowingStorage(Unreadable()), logger: logger.safe()),
      key: Self.key,
      logger: logger.safe(),
      defaultConsent: .granted,
      persists: true
    )

    consent.enforceAtInit(purging: purge)

    #expect(consent.consent == .denied)
    #expect(consent.isPending)
    #expect(purge.calls == ["dropQueue"])
    #expect(
      logger.warnings == [
        "Storage failed; state is kept in memory only until the app restarts",
        "The stored tracking consent could not be read, so it is denied until the user chooses: it may be an opt-out",
      ]
    )
    #expect(logger.debugs.isEmpty)
    consent.set(.granted, purging: purge)
    #expect(consent.isGranted)
  }

  @Test("consent that is not persisted is not read, so storage that fails changes nothing")
  func unreadButNotPersisted() {
    struct Unreadable: Error {}
    let consent = TrackingConsentController(
      storage: SafeStorage(ThrowingStorage(Unreadable()), logger: logger.safe()),
      key: Self.key,
      logger: logger.safe(),
      defaultConsent: .granted,
      persists: false
    )

    #expect(consent.isGranted)
    #expect(logger.warnings.isEmpty)
  }

  @Test("denying again purges again")
  func denyingAgain() {
    let consent = makeController()

    consent.set(.denied, purging: purge)
    consent.set(.denied, purging: purge)

    #expect(purge.calls == ["dropQueue", "forgetIdentity", "dropQueue", "forgetIdentity"])
  }

  private func makeController(
    default defaultConsent: Pug.TrackingConsent = .granted,
    persists: Bool = false
  ) -> TrackingConsentController {
    TrackingConsentController(
      storage: SafeStorage(memory, logger: logger.safe()),
      key: Self.key,
      logger: logger.safe(),
      defaultConsent: defaultConsent,
      persists: persists
    )
  }
}
