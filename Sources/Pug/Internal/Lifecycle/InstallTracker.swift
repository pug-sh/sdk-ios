/// `app_install` and `app_update`, once per app version (Flutter's InstallTracker). `check` decides at start, before
/// this launch writes anything, so the prior-activity probe sees earlier launches only. The stored version advances
/// only once the event is captured: an install that consent kept from being tracked is tracked by `emit` once the
/// user opts in.
final class InstallTracker {
  private struct Pending {
    let kind: String
    let properties: [String: String]
    let version: String
  }

  private let storage: SafeStorage
  private let keys: StorageKeys
  private let logger: SafeLogger
  private var pending: Pending?

  init(storage: SafeStorage, keys: StorageKeys, logger: SafeLogger) {
    self.storage = storage
    self.keys = keys
    self.logger = logger
  }

  func check(appVersion: String?, installSource: () -> String?) {
    pending = nil
    guard let appVersion, !appVersion.isEmpty else {
      logger.debug("app_install and app_update are not tracked: the app version could not be read")
      return
    }
    let lastVersion = storage.string(forKey: keys.lastVersion) ?? ""
    let ranBefore = lastVersion.isEmpty && keys.priorActivity.contains { storage.string(forKey: $0) != nil }
    // Memory holds nothing from earlier launches, so every launch would look like an install.
    guard !storage.hasFailedOver else {
      logger.debug("app_install and app_update are not tracked: storage could not be read")
      return
    }
    switch lastVersion {
    case appVersion:
      break
    case "" where ranBefore:
      // Pug ran here before it recorded a version: this app already used it, so this is an upgrade of a
      // known install rather than a new one.
      storage.setString(appVersion, forKey: keys.lastVersion)
    case "":
      var properties = ["appVersion": appVersion]
      properties["installSource"] = installSource()
      pending = Pending(kind: Pug.Events.appInstall, properties: properties, version: appVersion)
    default:
      pending = Pending(
        kind: Pug.Events.appUpdate,
        properties: ["appVersion": appVersion, "previousVersion": lastVersion],
        version: appVersion
      )
    }
  }

  /// Tracks the pending event, if any, through `capture`, which returns whether it was captured.
  func emit(_ capture: (_ kind: String, _ properties: [String: String]) -> Bool) {
    guard let event = pending, capture(event.kind, event.properties) else { return }
    pending = nil
    storage.setString(event.version, forKey: keys.lastVersion)
  }
}
