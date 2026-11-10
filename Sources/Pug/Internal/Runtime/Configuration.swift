import Foundation

/// `Pug.Options` checked and resolved for the runtime: numbers in range and durations in milliseconds.
struct Configuration: Sendable {
  // BatchCreateRequest.events is capped at 1000 by the server's validation rules.
  static let maxBatchSize = 1_000

  let projectId: String
  let apiKey: String
  let endpoint: URL
  let logger: SafeLogger
  let dryRun: Bool
  let batchMaxSize: Int
  let batchMaxWaitMillis: Int64
  let batchMaxQueueSize: Int
  let sessionIdleTimeoutMillis: Int64
  let sessionMaxDurationMillis: Int64
  let defaultTrackingConsent: Pug.TrackingConsent
  let persistTrackingConsent: Bool
  let autoOpenCloseEvents: Bool
  let autoScreenViews: Bool
  let autoInstallEvents: Bool
  let storage: (any Pug.Storage)?
  /// What was out of range and replaced, for `initialize` to log once this configuration is in use.
  let warnings: [String]

  init(projectId: String, options: Pug.Options) throws(Pug.ConfigurationError) {
    try Self.validate(projectId: projectId, options: options)
    let defaults = Pug.Options(apiKey: options.apiKey)
    var warnings: [String] = []
    self.projectId = projectId
    apiKey = options.apiKey
    endpoint = options.endpoint
    logger = SafeLogger(options.logger ?? SystemLogger(), isDebugEnabled: options.debug)
    dryRun = options.dryRun
    if options.batchMaxSize > Self.maxBatchSize {
      warnings.append("batchMaxSize \(options.batchMaxSize) is above the server's limit; using \(Self.maxBatchSize)")
      batchMaxSize = Self.maxBatchSize
    } else {
      batchMaxSize = Self.positive("batchMaxSize", options.batchMaxSize, default: defaults.batchMaxSize, &warnings)
    }
    batchMaxWaitMillis = Self.milliseconds(
      "batchMaxWait", options.batchMaxWait, atLeast: 0, default: defaults.batchMaxWait, &warnings)
    batchMaxQueueSize = Self.positive(
      "batchMaxQueueSize", options.batchMaxQueueSize, default: defaults.batchMaxQueueSize, &warnings)
    sessionIdleTimeoutMillis = Self.milliseconds(
      "sessionIdleTimeout", options.sessionIdleTimeout, atLeast: 1, default: defaults.sessionIdleTimeout, &warnings)
    sessionMaxDurationMillis = Self.milliseconds(
      "sessionMaxDuration", options.sessionMaxDuration, atLeast: 1, default: defaults.sessionMaxDuration, &warnings)
    defaultTrackingConsent = options.defaultTrackingConsent
    persistTrackingConsent = options.persistTrackingConsent
    autoOpenCloseEvents = options.autoOpenCloseEvents
    autoScreenViews = options.autoScreenViews
    autoInstallEvents = options.autoInstallEvents
    storage = options.storage
    self.warnings = warnings
  }

  private static func validate(projectId: String, options: Pug.Options) throws(Pug.ConfigurationError) {
    if projectId.allSatisfy(\.isWhitespace) {
      throw Pug.ConfigurationError("Pug.initialize() needs a project id")
    }
    if options.apiKey.allSatisfy(\.isWhitespace) {
      throw Pug.ConfigurationError("Pug.initialize() needs an API key")
    }
    // Keys are printable ASCII, so a space or a control character, such as the trailing newline of a pasted key,
    // would fail every request.
    if !options.apiKey.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) {
      throw Pug.ConfigurationError(
        "The Pug API key must be printable ASCII without spaces (check for a trailing newline)")
    }
    if !options.apiKey.hasUTF8Prefix("pub_") {
      throw Pug.ConfigurationError(
        "Pug.initialize() needs a public API key (pub_…), not a private key or the project id")
    }
    let scheme = options.endpoint.scheme?.lowercased()
    let isHTTP = scheme == "http" || scheme == "https"
    if !isHTTP || (options.endpoint.host ?? "").isEmpty {
      throw Pug.ConfigurationError(
        "The Pug endpoint must be an http(s) URL, not \"\(options.endpoint.absoluteString)\"")
    }
    // The paths of the calls are appended to the endpoint, so they would land in its query or fragment.
    if options.endpoint.query != nil || options.endpoint.fragment != nil {
      throw Pug.ConfigurationError(
        "The Pug endpoint must have no query or fragment: \"\(options.endpoint.absoluteString)\"")
    }
  }

  private static func positive(_ name: String, _ value: Int, default fallback: Int, _ warnings: inout [String]) -> Int {
    if value >= 1 {
      return value
    }
    warnings.append("\(name) \(value) must be at least 1; using \(fallback)")
    return fallback
  }

  private static func milliseconds(
    _ name: String,
    _ seconds: TimeInterval,
    atLeast minimum: Int64,
    default fallback: TimeInterval,
    _ warnings: inout [String]
  ) -> Int64 {
    let fallbackMillis = durationMilliseconds(fallback) ?? 0
    let replacement = "using \(durationText(milliseconds: fallbackMillis))"
    guard let millis = durationMilliseconds(seconds) else {
      warnings.append("\(name) \(seconds) is not a usable number of seconds; \(replacement)")
      return fallbackMillis
    }
    guard millis >= minimum else {
      warnings.append("\(name) \(seconds) must be at least \(durationText(milliseconds: minimum)); \(replacement)")
      return fallbackMillis
    }
    return millis
  }
}
