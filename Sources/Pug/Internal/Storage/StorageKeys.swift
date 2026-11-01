/// The family-wide `__pug_<projectId>_<name>__` key scheme.
struct StorageKeys: Sendable {
    let session: String
    let profile: String
    let externalId: String
    let queue: String
    let consent: String
    let lastVersion: String

    init(projectId: String) {
        func key(_ name: String) -> String {
            "__pug_\(projectId)_\(name)__"
        }
        session = key("session")
        profile = key("profile")
        externalId = key("external_id")
        queue = key("queue")
        consent = key("consent")
        lastVersion = key("last_version")
    }

    var all: [String] {
        [session, profile, externalId, queue, consent, lastVersion]
    }

    /// Keys whose presence shows the SDK has run on this device before, which tells an upgrade from a fresh install.
    /// Consent is a preference rather than activity (and outlives an opt-out purge), and the last version is what
    /// install detection is deciding.
    var priorActivity: [String] {
        [session, profile, externalId, queue]
    }
}
