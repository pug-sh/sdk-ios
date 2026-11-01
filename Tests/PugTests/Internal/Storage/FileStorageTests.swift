import Foundation
import Testing

@testable import Pug

final class FileStorageTests {
    private static let key = StorageKeys(projectId: "proj_1").queue
    private static let otherKey = StorageKeys(projectId: "proj_1").session

    private let root: URL
    private let directory: URL
    private let scheduler = TestScheduler()
    private let logger = RecordingLogger()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FileStorageTests-\(UUID().uuidString)")
        directory = root.appendingPathComponent("pug")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @Test("a change is read back at once and reaches the disk after the sync delay")
    func writeBehind() throws {
        let storage = makeStorage()

        storage.setString("v1", forKey: Self.key)
        #expect(try storage.string(forKey: Self.key) == "v1")
        scheduler.advanceTime(by: FileStorage.syncDelayMillis - 1)
        scheduler.runCurrent()
        #expect(!exists(Self.key))
        scheduler.advanceTime(by: 1)
        scheduler.runCurrent()

        #expect(try contents(Self.key) == "v1")
        #expect(logger.entries.isEmpty)
    }

    @Test("changes made within the delay reach the disk together")
    func batchedChanges() throws {
        let storage = makeStorage()
        storage.setString("old", forKey: Self.otherKey)
        storage.sync()

        storage.setString("v1", forKey: Self.key)
        scheduler.advanceTime(by: 500)
        storage.setString("v2", forKey: Self.key)
        storage.removeValue(forKey: Self.otherKey)
        scheduler.advanceTime(by: FileStorage.syncDelayMillis - 500)
        scheduler.runCurrent()

        #expect(try contents(Self.key) == "v2")
        #expect(!exists(Self.otherKey))
    }

    @Test("sync writes at once")
    func syncWritesAtOnce() throws {
        let storage = makeStorage()

        storage.setString("v1", forKey: Self.key)
        storage.sync()

        #expect(try contents(Self.key) == "v1")
        #expect(scheduler.currentTime == 0)
    }

    @Test("what one instance wrote, the next one reads")
    func survivesARestart() throws {
        let first = makeStorage()
        first.setString("\u{FC}n\u{EF}c\u{F6}d\u{E9} \u{2713} \u{1F30D}", forKey: Self.key)
        first.setString("gone", forKey: Self.otherKey)
        first.removeValue(forKey: Self.otherKey)
        first.sync()

        let second = makeStorage()

        #expect(try second.string(forKey: Self.key) == "\u{FC}n\u{EF}c\u{F6}d\u{E9} \u{2713} \u{1F30D}")
        #expect(try second.string(forKey: Self.otherKey) == nil)
    }

    @Test("a key is read from disk at most once")
    func readsOnce() throws {
        let storage = makeStorage()
        #expect(try storage.string(forKey: Self.key) == nil)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("written behind its back".utf8).write(to: file(Self.key))

        #expect(try storage.string(forKey: Self.key) == nil)
    }

    @Test("a leftover temporary file is ignored and replaced")
    func leftoverTemporaryFile() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(FileStorage.fileName(Self.key) + ".tmp")
        try Data("half-written".utf8).write(to: temp)
        let storage = makeStorage()

        #expect(try storage.string(forKey: Self.key) == nil)
        storage.setString("v1", forKey: Self.key)
        storage.sync()

        #expect(try contents(Self.key) == "v1")
        #expect(try listing() == [FileStorage.fileName(Self.key)])
    }

    @Test("a project id cannot lead outside the directory")
    func percentEncodedNames() throws {
        let storage = makeStorage()
        let key = StorageKeys(projectId: "../../etc/x y").queue

        storage.setString("v1", forKey: key)
        storage.sync()

        #expect(try listing() == ["__pug_..%2f..%2fetc%2fx%20y_queue__"])
        #expect(try makeStorage().string(forKey: key) == "v1")
    }

    @Test("a key too long for a file name is stored under its hash")
    func hashedNames() throws {
        let storage = makeStorage()
        let key = StorageKeys(projectId: String(repeating: "p", count: 300)).session

        storage.setString("v1", forKey: key)
        storage.sync()

        #expect(try listing() == ["sha256-4103bfe0f87b0ed19ef64a669c4e7bb336955e8b1ba4223f19ff02a644179777"])
        #expect(try makeStorage().string(forKey: key) == "v1")
    }

    @Test("bytes that are not UTF-8 read as replacement characters, not as a failure")
    func invalidUTF8() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([0x61, 0xFF, 0x62]).write(to: file(Self.key))

        #expect(try makeStorage().string(forKey: Self.key) == "a\u{FFFD}b")
    }

    @Test("a file that exists but cannot be read throws rather than reading as absent")
    func unreadableFileThrows() throws {
        // A directory where the file should be cannot be read.
        try FileManager.default.createDirectory(at: file(Self.key), withIntermediateDirectories: true)
        let storage = makeStorage()

        #expect(throws: (any Error).self) { try storage.string(forKey: Self.key) }
        #expect(try storage.string(forKey: Self.otherKey) == nil)
    }

    @Test("an unreadable file moves the client to memory and leaves the files as they were")
    func unreadableFileFailsOver() throws {
        try FileManager.default.createDirectory(at: file(Self.key), withIntermediateDirectories: true)
        let files = makeStorage()
        let storage = SafeStorage(files, logger: logger.safe())

        #expect(storage.string(forKey: Self.key) == nil)
        storage.setString("v1", forKey: Self.otherKey)
        files.sync()

        #expect(storage.hasFailedOver)
        #expect(storage.string(forKey: Self.otherKey) == "v1")
        #expect(logger.warnings == ["Storage failed; state is kept in memory only until the app restarts"])
        #expect(!exists(Self.otherKey))
    }

    @Test("a failed write is logged once and retried with the next change")
    func failedWrites() throws {
        // A file where the directory should be makes every write fail.
        try Data("in the way".utf8).write(to: directory)
        let storage = makeStorage()

        storage.setString("v1", forKey: Self.key)
        storage.sync()
        storage.setString("v2", forKey: Self.key)
        storage.sync()
        #expect(logger.warnings.count == 1)
        #expect(logger.warnings.first?.hasPrefix("Storage could not be written") == true)
        #expect(logger.debugs == ["Storage still cannot be written; state is kept in memory meanwhile"])
        #expect(try storage.string(forKey: Self.key) == "v2")

        try FileManager.default.removeItem(at: directory)
        storage.setString("v3", forKey: Self.otherKey)
        scheduler.advanceTime(by: FileStorage.syncDelayMillis)
        scheduler.runCurrent()

        #expect(try contents(Self.key) == "v2")
        #expect(try contents(Self.otherKey) == "v3")
    }

    @Test("a storage nothing references any more writes nothing behind")
    func releasedStorage() {
        var storage: FileStorage? = makeStorage()

        storage?.setString("v1", forKey: Self.key)
        storage = nil
        scheduler.advanceUntilIdle()

        #expect(!exists(Self.key))
    }

    private func makeStorage() -> FileStorage {
        FileStorage(directory: directory, logger: logger.safe(), scheduler: scheduler)
    }

    private func file(_ key: String) -> URL {
        directory.appendingPathComponent(FileStorage.fileName(key))
    }

    private func exists(_ key: String) -> Bool {
        FileManager.default.fileExists(atPath: file(key).path)
    }

    private func contents(_ key: String) throws -> String {
        String(decoding: try Data(contentsOf: file(key)), as: UTF8.self)
    }

    private func listing() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }
}
