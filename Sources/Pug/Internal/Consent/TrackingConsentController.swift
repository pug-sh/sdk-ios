/// What opting out purges, in the client that owns the queue and the identity.
protocol ConsentPurge {
  var isIdentified: Bool { get }

  func dropQueue()

  func forgetIdentity()
}

/// The consent state and its side effects (sdk-web semantics). Denying consent drops the queue unsent and forgets
/// the identity, through the purge each call is given; granting it again mints a fresh identity on the next event.
/// Built before the queue and the identity it purges, so that storage is read for consent first.
final class TrackingConsentController {
  private let storage: SafeStorage
  private let key: String
  private let logger: SafeLogger
  private let persists: Bool

  private(set) var consent: Pug.TrackingConsent

  // Whether consent is a user's choice, restored or made in this process, rather than the default. At init,
  // before any set(_:purging:), it means a stored choice: only a recorded denial may purge identity there, since
  // purging on a default would mint a new user on every launch.
  private var isDecided = false

  // Whether the stored choice could not be read, so that consent is denied rather than the default.
  private var isUnreadable = false

  init(storage: SafeStorage, key: String, logger: SafeLogger, defaultConsent: Pug.TrackingConsent, persists: Bool) {
    self.storage = storage
    self.key = key
    self.logger = logger
    self.persists = persists
    consent = defaultConsent
    if persists {
      restore()
    }
  }

  var isGranted: Bool {
    consent == .granted
  }

  /// The user has not chosen yet, so `consent` is still the configured default.
  var isPending: Bool {
    !isDecided
  }

  /// Brings the device in line with a denied consent at init, once the queue and identity exist.
  func enforceAtInit(purging purge: some ConsentPurge) {
    guard !isGranted else { return }
    purge.dropQueue()
    if isDecided {
      purge.forgetIdentity()
      logger.debug("Tracking consent is denied by a stored choice; events and identify() are dropped")
      return
    }
    // restore() warned, and the identity in memory holds no external id.
    guard !isUnreadable else { return }
    logger.debug("Tracking consent is denied by default; events and identify() are dropped until opt-in")
    if purge.isIdentified {
      let fix = persists ? "Call optOutTracking()" : "Persist consent, or call optOutTracking()"
      logger.warning(
        "Tracking consent is denied by default, but an external id from an earlier identify() is kept: a "
          + "default is not the user's choice. \(fix) once the user declines")
    }
  }

  func set(_ consent: Pug.TrackingConsent, purging purge: some ConsentPurge) {
    isDecided = true
    self.consent = consent
    if persists {
      storage.setString(consent.storedName, forKey: key)
    }
    if consent == .denied {
      purge.dropQueue()
      purge.forgetIdentity()
    }
  }

  private func restore() {
    guard let stored = storage.string(forKey: key) else {
      // Storage that cannot be read may hold an opt-out, which the default must not override.
      if storage.hasFailedOver {
        consent = .denied
        isUnreadable = true
        logger.warning(
          "The stored tracking consent could not be read, so it is denied until the user chooses: it may be an "
            + "opt-out")
      }
      return
    }
    guard let restored = Pug.TrackingConsent(storedName: stored) else {
      logger.warning("The stored tracking consent \"\(stored)\" is not valid and was ignored")
      return
    }
    consent = restored
    isDecided = true
  }
}

// The family's persisted form, shared with sdk-web, sdk-flutter and sdk-android.
extension Pug.TrackingConsent {
  fileprivate init?(storedName: String) {
    switch storedName {
    case "granted":
      self = .granted
    case "denied":
      self = .denied
    default:
      return nil
    }
  }

  fileprivate var storedName: String {
    switch self {
    case .granted:
      return "granted"
    case .denied:
      return "denied"
    }
  }
}
