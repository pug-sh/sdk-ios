import Testing

@testable import Pug

struct IdentityTests {
  private static let idle: Int64 = 30 * 60_000
  private static let maxDuration: Int64 = 24 * 60 * 60_000

  private let memory = Pug.MemoryStorage()
  private let keys = StorageKeys(projectId: "proj_1")
  private let logger = RecordingLogger()
  private let ids = SequentialIds()

  @Test("nothing is written until an id is needed")
  func writesNothingUpFront() {
    _ = makeIdentity()

    #expect(keys.all.allSatisfy { memory.string(forKey: $0) == nil })
  }

  @Test("the anonymous id is minted once and stored")
  func mintsTheAnonymousIdOnce() {
    let identity = makeIdentity()

    let anonymousId = identity.anonymousId

    #expect(anonymousId == "anon-00000000-0000-7000-8000-000000000001")
    #expect(identity.anonymousId == anonymousId)
    #expect(identity.distinctId == anonymousId)
    #expect(memory.string(forKey: keys.profile) == #"{"anonymousId":"\#(anonymousId)"}"#)
  }

  @Test("a session continues while events keep coming")
  func sessionContinues() {
    let identity = makeIdentity()

    let first = identity.sessionId(at: 1_000)
    let second = identity.sessionId(at: 1_000 + Self.idle)

    #expect(first == second)
    #expect(
      memory.string(forKey: keys.session)
        == #"{"sessionId":"\#(first)","startTime":1000,"lastActivityTime":\#(1_000 + Self.idle)}"#
    )
  }

  @Test("a session idle for longer than the timeout is replaced")
  func idleSessionIsReplaced() throws {
    let identity = makeIdentity()

    let first = identity.sessionId(at: 1_000)
    let second = identity.sessionId(at: 1_000 + Self.idle + 1)

    #expect(first != second)
    #expect(try storedSessionTime("startTime") == 1_000 + Self.idle + 1)
  }

  @Test("a session running past its maximum duration is replaced")
  func longSessionIsReplaced() {
    let identity = makeIdentity()
    let first = identity.sessionId(at: 0)

    var now: Int64 = 0
    while now + Self.idle <= Self.maxDuration {
      now += Self.idle
      #expect(identity.sessionId(at: now) == first)
    }
    let next = identity.sessionId(at: Self.maxDuration + 1)

    #expect(next != first)
  }

  @Test("state survives a restart")
  func survivesARestart() {
    let before = makeIdentity()
    let sessionId = before.sessionId(at: 1_000)
    before.link("user-42")
    let anonymousId = before.anonymousId

    let after = makeIdentity()

    #expect(after.sessionId(at: 2_000) == sessionId)
    #expect(after.anonymousId == anonymousId)
    #expect(after.externalId == "user-42")
    #expect(after.distinctId == "user-42")
  }

  @Test("linking stores the external id in the profile and under its own key")
  func link() {
    let identity = makeIdentity()

    identity.link("user-42")

    let anonymousId = identity.anonymousId
    #expect(
      memory.string(forKey: keys.profile) == #"{"anonymousId":"\#(anonymousId)","externalId":"user-42"}"#
    )
    #expect(memory.string(forKey: keys.externalId) == "user-42")
    #expect(identity.distinctId == "user-42")
  }

  @Test("an external id stored without a profile is kept")
  func externalIdWithoutProfile() {
    memory.setString("user-42", forKey: keys.externalId)

    let identity = makeIdentity()

    #expect(identity.distinctId == "user-42")
    #expect(identity.anonymousId.hasPrefix("anon-"))
  }

  @Test("reset starts a new anonymous user and session")
  func reset() {
    let identity = makeIdentity()
    let oldSession = identity.sessionId(at: 1_000)
    identity.link("user-42")
    let oldAnonymousId = identity.anonymousId

    identity.reset(at: 2_000)

    #expect(identity.externalId == nil)
    #expect(identity.anonymousId != oldAnonymousId)
    #expect(identity.distinctId == identity.anonymousId)
    #expect(identity.sessionId(at: 2_001) != oldSession)
    #expect(memory.string(forKey: keys.externalId) == nil)
    #expect(memory.string(forKey: keys.profile) == #"{"anonymousId":"\#(identity.anonymousId)"}"#)
    #expect(!identity.isCurrentAnonymousId(oldAnonymousId))
  }

  @Test("rotating keeps the user and replaces the session")
  func rotateSession() throws {
    let identity = makeIdentity()
    let session = identity.sessionId(at: 1_000)
    let anonymousId = identity.anonymousId

    identity.rotateSession(at: 1_500)

    #expect(identity.sessionId(at: 1_600) != session)
    #expect(identity.anonymousId == anonymousId)
    #expect(try storedSessionTime("startTime") == 1_500)
  }

  @Test("clearing forgets everything until the next use")
  func clear() {
    let identity = makeIdentity()
    _ = identity.sessionId(at: 1_000)
    identity.link("user-42")
    let anonymousId = identity.anonymousId

    identity.clear()

    #expect([keys.session, keys.profile, keys.externalId].allSatisfy { memory.string(forKey: $0) == nil })
    #expect(identity.externalId == nil)
    #expect(!identity.isCurrentAnonymousId(anonymousId))
    #expect(identity.anonymousId != anonymousId)
  }

  @Test("isCurrentAnonymousId never mints")
  func isCurrentAnonymousIdNeverMints() {
    let identity = makeIdentity()

    #expect(!identity.isCurrentAnonymousId("anon-x"))
    #expect(memory.string(forKey: keys.profile) == nil)
    #expect(identity.isCurrentAnonymousId(identity.anonymousId))
  }

  @Test("unreadable state is replaced")
  func unreadableState() {
    memory.setString("{not json", forKey: keys.session)
    memory.setString("[]", forKey: keys.profile)

    let identity = makeIdentity()

    #expect(identity.sessionId(at: 1) == "00000000-0000-7000-8000-000000000001")
    #expect(identity.anonymousId == "anon-00000000-0000-7000-8000-000000000002")
    #expect(
      logger.warnings == Array(repeating: "Stored identity state could not be read and was ignored", count: 2)
    )
  }

  @Test("a session the server would reject is replaced")
  func incompleteSessions() {
    let sessions = [
      #"{"sessionId":"not-a-uuid","startTime":1,"lastActivityTime":1}"#,
      #"{"sessionId":"00000000-0000-7000-8000-000000000099","startTime":"1","lastActivityTime":1}"#,
      #"{"sessionId":"00000000-0000-7000-8000-000000000099","startTime":true,"lastActivityTime":1}"#,
      #"{"sessionId":"00000000-0000-7000-8000-000000000099","startTime":1,"lastActivityTime":1e300}"#,
      #"{"startTime":1,"lastActivityTime":1}"#,
    ]
    for session in sessions {
      memory.setString(session, forKey: keys.session)

      let sessionId = makeIdentity().sessionId(at: 2)

      #expect(sessionId != "00000000-0000-7000-8000-000000000099", "\(session)")
    }
    #expect(
      logger.warnings
        == Array(
          repeating: "The stored session is incomplete; the next event starts a new one",
          count: sessions.count
        )
    )
  }

  @Test("a stored session time too far from now to subtract starts a new session")
  func extremeSessionTimes() {
    for (start, last) in [(Int64.min, Int64.min), (0, Int64.min), (Int64.min, 0)] {
      memory.setString(
        #"{"sessionId":"00000000-0000-7000-8000-000000000099","startTime":\#(start),"#
          + #""lastActivityTime":\#(last)}"#,
        forKey: keys.session
      )

      let sessionId = makeIdentity().sessionId(at: 1_760_000_000_000)

      #expect(sessionId != "00000000-0000-7000-8000-000000000099", "\(start), \(last)")
    }
    #expect(logger.entries.isEmpty)
  }

  @Test("an anonymous id without its prefix is replaced")
  func unprefixedAnonymousId() {
    memory.setString(#"{"anonymousId":"0192f3a4"}"#, forKey: keys.profile)

    let identity = makeIdentity()

    #expect(identity.anonymousId == "anon-00000000-0000-7000-8000-000000000001")
    #expect(logger.warnings == [#"The stored anonymous id lacks the "anon-" prefix; a new one will be used"#])
  }

  @Test(
    "an external id with a reserved prefix is discarded and the device healed", arguments: ["cookieless-", "crawler-"])
  func reservedExternalId(prefix: String) {
    memory.setString(#"{"anonymousId":"anon-1","externalId":"\#(prefix)abc"}"#, forKey: keys.profile)
    memory.setString("\(prefix)abc", forKey: keys.externalId)

    let identity = makeIdentity()

    #expect(identity.externalId == nil)
    #expect(identity.distinctId == "anon-1")
    #expect(memory.string(forKey: keys.externalId) == nil)
    #expect(memory.string(forKey: keys.profile) == #"{"anonymousId":"anon-1"}"#)
    #expect(logger.warnings.count == 1)
    #expect(
      logger.warnings.first?.hasPrefix(#"The stored external id uses the reserved "\#(prefix)" prefix"#) == true
    )
  }

  // The server compares bytes, where hasPrefix would compare the hyphen and the mark joined to it as one character.
  @Test("a reserved prefix matches on UTF-8 bytes, even when a combining mark joins its hyphen")
  func reservedPrefixBytes() {
    #expect(Identity.reservedPrefix(of: "crawler-\u{301}x") == "crawler-")
    #expect(Identity.reservedPrefix(of: "cookieless-\u{301}x") == "cookieless-")
    #expect(Identity.reservedPrefix(of: "crawlers-1") == nil)
  }

  private func storedSessionTime(_ name: String) throws -> Int64? {
    let session = try #require(StoredJSON.parse(memory.string(forKey: keys.session) ?? "") as? [String: Any])
    return StoredJSON.int64(session[name])
  }

  private func makeIdentity() -> Identity {
    Identity(
      storage: SafeStorage(memory, logger: logger.safe()),
      keys: keys,
      logger: logger.safe(),
      ids: ids,
      idleTimeoutMillis: Self.idle,
      maxDurationMillis: Self.maxDuration
    )
  }
}
