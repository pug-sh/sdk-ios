import Foundation

/// The default storage: one file per key in `directory`, each read at most once. A change lands in memory at once
/// and reaches the disk `syncDelayMillis` later together with the changes made meanwhile, or at `sync()`, so a burst
/// of events rewrites the queue file once rather than once per event. Confined to the worker, like every storage.
final class FileStorage: Pug.Storage, @unchecked Sendable {
  // Long enough to turn a burst of events into one write per key, short enough that a process killed without
  // warning loses little.
  static let syncDelayMillis: Int64 = 1_000
  // Well under the 255-byte name limit of Apple's file systems.
  private static let maxFileNameLength = 128
  private static let tempSuffix = ".tmp"
  #if os(iOS) && !targetEnvironment(macCatalyst)
  // The default for an app's files, explicit for an app whose own default is stronger: Pug also runs in the
  // background while the device is locked.
  private static let writingOptions: Data.WritingOptions = .completeFileProtectionUntilFirstUserAuthentication
  #else
  private static let writingOptions: Data.WritingOptions = []
  #endif

  private let directory: URL
  private let logger: SafeLogger
  private let scheduler: any Scheduler
  // A nil value is a key known to be absent.
  private var values: [String: String?] = [:]
  private var unsynced: Set<String> = []
  private var scheduledSync: (any Cancellable)?
  private var failing = false
  private var isDirectoryExcluded = false

  init(directory: URL, logger: SafeLogger, scheduler: any Scheduler) {
    self.directory = directory
    self.logger = logger
    self.scheduler = scheduler
  }

  // A file that exists but cannot be read, as before the first unlock after a reboot, throws rather than reading
  // as absent: an absent key would mint a new identity over the stored one and track a false app_install.
  func string(forKey key: String) throws -> String? {
    assert(scheduler.isOnWorker)
    if let value = values[key] {
      return value
    }
    let file = fileURL(key)
    let value: String?
    do {
      value = String(decoding: try Data(contentsOf: file), as: UTF8.self)
    } catch {
      guard !FileManager.default.fileExists(atPath: file.path) else { throw error }
      value = nil
    }
    values.updateValue(value, forKey: key)
    return value
  }

  /// Whether every one of `keys` can be read now. What it reads is kept, as by `string(forKey:)`.
  func canRead(_ keys: [String]) -> Bool {
    do {
      for key in keys {
        _ = try string(forKey: key)
      }
      return true
    } catch {
      return false
    }
  }

  func setString(_ value: String, forKey key: String) {
    change(key, to: value)
  }

  func removeValue(forKey key: String) {
    change(key, to: nil)
  }

  /// Writes every change not yet on disk. A write that fails is logged and retried at the next sync.
  func sync() {
    assert(scheduler.isOnWorker)
    scheduledSync?.cancel()
    scheduledSync = nil
    guard !unsynced.isEmpty else { return }
    var failure: (any Error)?
    for key in unsynced.sorted() {
      do {
        try write(values[key] ?? nil, forKey: key)
        unsynced.remove(key)
      } catch {
        failure = error
      }
    }
    report(failure)
  }

  /// Keys embed the host's project id, so anything outside `[A-Za-z0-9_.-]` is percent-encoded, and a name too
  /// long for the file system is replaced by its hash.
  static func fileName(_ key: String) -> String {
    var name: [UInt8] = []
    for byte in key.utf8 {
      switch byte {
      case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
        UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "-"):
        name.append(byte)
      default:
        name.append(UInt8(ascii: "%"))
        name.appendHex(byte)
      }
    }
    if name.count > maxFileNameLength {
      name = Array("sha256-".utf8)
      for byte in SHA256.digest(Array(key.utf8)) {
        name.appendHex(byte)
      }
    }
    return String(decoding: name, as: UTF8.self)
  }

  private func change(_ key: String, to value: String?) {
    assert(scheduler.isOnWorker)
    if let current = values[key], current == value {
      return
    }
    values.updateValue(value, forKey: key)
    unsynced.insert(key)
    guard scheduledSync == nil else { return }
    scheduledSync = scheduler.runAfter(milliseconds: Self.syncDelayMillis) { [weak self] in
      self?.sync()
    }
  }

  private func write(_ value: String?, forKey key: String) throws {
    let fileManager = FileManager.default
    let file = fileURL(key)
    guard let value else {
      if fileManager.fileExists(atPath: file.path) {
        try fileManager.removeItem(at: file)
      }
      return
    }
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    excludeDirectoryFromBackup()
    let temp = directory.appendingPathComponent(Self.fileName(key) + Self.tempSuffix, isDirectory: false)
    try Data(value.utf8).write(to: temp, options: Self.writingOptions)
    // The rename must not publish a file whose content a power loss could still undo.
    do {
      let handle = try FileHandle(forWritingTo: temp)
      defer { try? handle.close() }
      try handle.synchronize()
    }
    guard rename(temp.path, file.path) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  // A backup restored onto another device would make two installs one user.
  private func excludeDirectoryFromBackup() {
    guard !isDirectoryExcluded else { return }
    isDirectoryExcluded = true
    #if canImport(Darwin)
    var url = directory
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    do {
      try url.setResourceValues(values)
    } catch {
      logger.warning("The storage directory could not be excluded from backups", error: error)
    }
    #endif
  }

  private func report(_ failure: (any Error)?) {
    guard let failure else {
      failing = false
      return
    }
    if failing {
      logger.debug("Storage still cannot be written; state is kept in memory meanwhile")
      return
    }
    failing = true
    logger.warning(
      "Storage could not be written; state is kept in memory and written with the next change. Until a write "
        + "succeeds, failures are logged at debug level",
      error: failure
    )
  }

  private func fileURL(_ key: String) -> URL {
    directory.appendingPathComponent(Self.fileName(key), isDirectory: false)
  }
}
