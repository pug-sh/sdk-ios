import Testing

@testable import Pug

struct SafeStorageTests {
    private struct Failure: Error, Equatable {
        let reason: String
    }

    private struct ReadOnlyStorage: Pug.Storage {
        func string(forKey key: String) -> String? {
            "stored"
        }

        func setString(_ value: String, forKey key: String) throws {
            throw Failure(reason: "read-only")
        }

        func removeValue(forKey key: String) {}
    }

    private let logger = RecordingLogger()

    @Test("a healthy store is used directly")
    func healthyStore() {
        let primary = Pug.MemoryStorage()
        let storage = SafeStorage(primary, logger: logger.safe())

        storage.setString("1", forKey: "a")
        storage.setString("2", forKey: "b")
        storage.removeValue(forKey: "b")

        #expect(primary.string(forKey: "a") == "1")
        #expect(primary.string(forKey: "b") == nil)
        #expect(storage.string(forKey: "a") == "1")
        #expect(!storage.hasFailedOver)
        #expect(logger.entries.isEmpty)
    }

    @Test("the first failure moves every later call to memory")
    func failsOverOnce() throws {
        let primary = ThrowingStorage(Failure(reason: "disk full"))
        let storage = SafeStorage(primary, logger: logger.safe())

        storage.setString("1", forKey: "a")
        storage.setString("2", forKey: "b")
        storage.removeValue(forKey: "b")

        #expect(storage.string(forKey: "a") == "1")
        #expect(storage.string(forKey: "b") == nil)
        #expect(storage.hasFailedOver)
        #expect(primary.calls == 1)
        let entries = logger.entries
        try #require(entries.count == 1)
        #expect(entries[0].level == "warning")
        #expect(entries[0].message == "Storage failed; state is kept in memory only until the app restarts")
        #expect(entries[0].error as? Failure == Failure(reason: "disk full"))
    }

    @Test("a failed read reports nothing stored")
    func failedRead() {
        let storage = SafeStorage(ThrowingStorage(Failure(reason: "locked")), logger: logger.safe())

        #expect(storage.string(forKey: "a") == nil)
        #expect(storage.hasFailedOver)
        storage.setString("1", forKey: "a")
        #expect(storage.string(forKey: "a") == "1")
    }

    @Test("any error from host storage is contained, cancellation included")
    func containsAnyError() {
        let storage = SafeStorage(ThrowingStorage(CancellationError()), logger: logger.safe())

        storage.removeValue(forKey: "a")
        storage.setString("1", forKey: "a")

        #expect(storage.string(forKey: "a") == "1")
    }

    @Test("a store that fails only on writes keeps serving what was read")
    func failsOnlyOnWrites() {
        let storage = SafeStorage(ReadOnlyStorage(), logger: logger.safe())

        #expect(storage.string(forKey: "a") == "stored")
        storage.setString("new", forKey: "a")

        #expect(storage.string(forKey: "a") == "new")
    }

    @Test("memory storage round-trips")
    func memoryStorage() {
        let storage = Pug.MemoryStorage()

        storage.setString("1", forKey: "a")
        storage.setString("2", forKey: "a")
        storage.removeValue(forKey: "missing")

        #expect(storage.string(forKey: "a") == "2")
        storage.removeValue(forKey: "a")
        #expect(storage.string(forKey: "a") == nil)
    }

    @Test("keys follow the family scheme")
    func keys() {
        let keys = StorageKeys(projectId: "proj_1")

        #expect(
            keys.all == [
                "__pug_proj_1_session__",
                "__pug_proj_1_profile__",
                "__pug_proj_1_external_id__",
                "__pug_proj_1_queue__",
                "__pug_proj_1_consent__",
                "__pug_proj_1_last_version__",
            ]
        )
        #expect(keys.priorActivity == [keys.session, keys.profile, keys.externalId, keys.queue])
    }
}
