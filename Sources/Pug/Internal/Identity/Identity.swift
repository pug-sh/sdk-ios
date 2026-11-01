/// Who is tracking: the session, the anonymous id and the external id from `identify`. State lives in memory and is
/// written through to storage. Ids are minted on first use rather than on load, so a client whose consent is denied
/// never writes one.
final class Identity {
    /// The server mints cookieless ids with this prefix and rejects any batch whose distinct id has it.
    static let reservedIdPrefix = "cookieless-"
    static let anonymousIdPrefix = "anon-"

    private struct Session {
        let id: String
        let startTime: Int64
        let lastActivityTime: Int64
    }

    private let storage: SafeStorage
    private let keys: StorageKeys
    private let logger: SafeLogger
    private let ids: any IdGenerator
    private let idleTimeoutMillis: Int64
    private let maxDurationMillis: Int64
    private var session: Session?
    private var currentAnonymousId: String?

    private(set) var externalId: String?

    init(
        storage: SafeStorage,
        keys: StorageKeys,
        logger: SafeLogger,
        ids: any IdGenerator,
        idleTimeoutMillis: Int64,
        maxDurationMillis: Int64
    ) {
        self.storage = storage
        self.keys = keys
        self.logger = logger
        self.ids = ids
        self.idleTimeoutMillis = idleTimeoutMillis
        self.maxDurationMillis = maxDurationMillis
        session = restoreSession()
        restoreProfile()
    }

    /// Minted and stored on first use.
    var anonymousId: String {
        if let currentAnonymousId {
            return currentAnonymousId
        }
        let minted = newAnonymousId()
        currentAnonymousId = minted
        storeProfile()
        return minted
    }

    var distinctId: String {
        externalId ?? anonymousId
    }

    /// Whether `anonymousId` is still the current one, without minting one if there is none.
    func isCurrentAnonymousId(_ anonymousId: String) -> Bool {
        currentAnonymousId == anonymousId
    }

    /// The session for an event at `nowMillis`: the current one, or a new one if it idled out or ran too long.
    func sessionId(at nowMillis: Int64) -> String {
        let next =
            if let current = session, !hasExpired(current, at: nowMillis) {
                Session(id: current.id, startTime: current.startTime, lastActivityTime: nowMillis)
            } else {
                Session(id: ids.nextId(), startTime: nowMillis, lastActivityTime: nowMillis)
            }
        store(next)
        return next.id
    }

    func rotateSession(at nowMillis: Int64) {
        store(Session(id: ids.nextId(), startTime: nowMillis, lastActivityTime: nowMillis))
    }

    func link(_ externalId: String) {
        self.externalId = externalId
        if currentAnonymousId == nil {
            currentAnonymousId = newAnonymousId()
        }
        storeProfile()
        storage.setString(externalId, forKey: keys.externalId)
    }

    func reset(at nowMillis: Int64) {
        externalId = nil
        currentAnonymousId = newAnonymousId()
        storeProfile()
        storage.removeValue(forKey: keys.externalId)
        rotateSession(at: nowMillis)
    }

    /// Forgets everything, on the device too; the next event mints a new identity.
    func clear() {
        session = nil
        currentAnonymousId = nil
        externalId = nil
        storage.removeValue(forKey: keys.session)
        storage.removeValue(forKey: keys.profile)
        storage.removeValue(forKey: keys.externalId)
    }

    private func newAnonymousId() -> String {
        Self.anonymousIdPrefix + ids.nextId()
    }

    // A stored time can be anything: one too far from now to subtract has expired.
    private func hasExpired(_ session: Session, at nowMillis: Int64) -> Bool {
        let idle = nowMillis.subtractingReportingOverflow(session.lastActivityTime)
        let age = nowMillis.subtractingReportingOverflow(session.startTime)
        return idle.overflow || age.overflow || idle.partialValue > idleTimeoutMillis
            || age.partialValue > maxDurationMillis
    }

    private func restoreSession() -> Session? {
        guard let json = readJSON(keys.session) else { return nil }
        guard let id = json["sessionId"] as? String, id.isUUID,
            let startTime = StoredJSON.int64(json["startTime"]),
            let lastActivityTime = StoredJSON.int64(json["lastActivityTime"])
        else {
            logger.warning("The stored session is incomplete; the next event starts a new one")
            return nil
        }
        return Session(id: id, startTime: startTime, lastActivityTime: lastActivityTime)
    }

    private func restoreProfile() {
        let profile = readJSON(keys.profile)
        var anonymousId = profile?["anonymousId"] as? String
        if let id = anonymousId, !id.hasUTF8Prefix(Self.anonymousIdPrefix) {
            logger.warning(
                "The stored anonymous id lacks the \"\(Self.anonymousIdPrefix)\" prefix; a new one will be used")
            anonymousId = nil
        }
        var externalId = profile?["externalId"] as? String ?? storage.string(forKey: keys.externalId)
        // Written by an identify the server accepted before it reserved the prefix. As the distinct id it fails
        // every batch it is in, healthy events included.
        let reserved = externalId?.hasUTF8Prefix(Self.reservedIdPrefix) == true
        if reserved {
            logger.warning(
                "The stored external id uses the reserved \"\(Self.reservedIdPrefix)\" prefix and was discarded; "
                    + "the user is anonymous until identify() is called again")
            externalId = nil
        }
        currentAnonymousId = anonymousId
        self.externalId = externalId == "" ? nil : externalId
        if reserved {
            storage.removeValue(forKey: keys.externalId)
            storeProfile()
        }
    }

    private func readJSON(_ key: String) -> [String: Any]? {
        guard let raw = storage.string(forKey: key) else { return nil }
        guard let json = StoredJSON.parse(raw) as? [String: Any] else {
            logger.warning("Stored identity state could not be read and was ignored")
            return nil
        }
        return json
    }

    private func store(_ session: Session) {
        self.session = session
        let json = JSONWriter()
            .beginObject()
            .name("sessionId").value(session.id)
            .name("startTime").value(session.startTime)
            .name("lastActivityTime").value(session.lastActivityTime)
            .endObject()
        storage.setString(json.text, forKey: keys.session)
    }

    private func storeProfile() {
        guard let anonymousId = currentAnonymousId else {
            storage.removeValue(forKey: keys.profile)
            return
        }
        let json = JSONWriter().beginObject().name("anonymousId").value(anonymousId)
        if let externalId {
            json.name("externalId").value(externalId)
        }
        storage.setString(json.endObject().text, forKey: keys.profile)
    }
}
