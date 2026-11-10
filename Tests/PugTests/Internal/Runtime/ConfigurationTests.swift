import Foundation
import Testing

@testable import Pug

struct ConfigurationTests {
  private static let project = "proj_1"

  @Test("the defaults resolve to the family's, in milliseconds")
  func defaults() throws {
    let configuration = try Configuration(projectId: Self.project, options: Pug.Options(apiKey: "pub_test"))

    #expect(configuration.projectId == Self.project)
    #expect(configuration.apiKey == "pub_test")
    #expect(configuration.endpoint.absoluteString == "https://api.pugs.dev")
    #expect(!configuration.logger.isDebugEnabled)
    #expect(!configuration.dryRun)
    #expect(configuration.batchMaxSize == 10)
    #expect(configuration.batchMaxWaitMillis == 5_000)
    #expect(configuration.batchMaxQueueSize == 1_000)
    #expect(configuration.sessionIdleTimeoutMillis == 30 * 60_000)
    #expect(configuration.sessionMaxDurationMillis == 24 * 60 * 60_000)
    #expect(configuration.defaultTrackingConsent == .granted)
    #expect(configuration.persistTrackingConsent)
    #expect(configuration.autoOpenCloseEvents)
    #expect(configuration.autoScreenViews)
    #expect(configuration.autoInstallEvents)
    #expect(configuration.storage == nil)
    #expect(configuration.warnings.isEmpty)
  }

  @Test("each option is resolved as set, durations rounded to the millisecond")
  func options() throws {
    let logger = RecordingLogger()
    let storage = Pug.MemoryStorage()
    var options = Pug.Options(apiKey: "pub_test")
    options.endpoint = try #require(URL(string: "https://eu.pugs.dev"))
    options.debug = true
    options.dryRun = true
    options.batchMaxSize = 20
    options.batchMaxWait = 1.5
    options.batchMaxQueueSize = 50
    options.sessionIdleTimeout = 60.0004
    options.sessionMaxDuration = 120
    options.defaultTrackingConsent = .denied
    options.persistTrackingConsent = false
    options.autoOpenCloseEvents = false
    options.autoScreenViews = false
    options.autoInstallEvents = false
    options.logger = logger
    options.storage = storage

    let configuration = try Configuration(projectId: Self.project, options: options)
    configuration.logger.debug("through the host's logger")

    #expect(configuration.endpoint.absoluteString == "https://eu.pugs.dev")
    #expect(configuration.dryRun)
    #expect(configuration.batchMaxSize == 20)
    #expect(configuration.batchMaxWaitMillis == 1_500)
    #expect(configuration.batchMaxQueueSize == 50)
    #expect(configuration.sessionIdleTimeoutMillis == 60_000)
    #expect(configuration.sessionMaxDurationMillis == 120_000)
    #expect(configuration.defaultTrackingConsent == .denied)
    #expect(!configuration.persistTrackingConsent)
    #expect(!configuration.autoOpenCloseEvents)
    #expect(!configuration.autoScreenViews)
    #expect(!configuration.autoInstallEvents)
    #expect(configuration.storage as? Pug.MemoryStorage === storage)
    #expect(logger.debugs == ["through the host's logger"])
    #expect(configuration.warnings.isEmpty)
  }

  @Test("numbers out of range are replaced by their defaults, with a warning each")
  func outOfRange() throws {
    var options = Pug.Options(apiKey: "pub_test")
    options.batchMaxSize = 0
    options.batchMaxWait = -1
    options.batchMaxQueueSize = 0
    options.sessionIdleTimeout = 0.0004
    options.sessionMaxDuration = -5

    let configuration = try Configuration(projectId: Self.project, options: options)

    #expect(configuration.batchMaxSize == 10)
    #expect(configuration.batchMaxWaitMillis == 5_000)
    #expect(configuration.batchMaxQueueSize == 1_000)
    #expect(configuration.sessionIdleTimeoutMillis == 30 * 60_000)
    #expect(configuration.sessionMaxDurationMillis == 24 * 60 * 60_000)
    #expect(
      configuration.warnings == [
        "batchMaxSize 0 must be at least 1; using 10",
        "batchMaxWait -1.0 must be at least 0s; using 5s",
        "batchMaxQueueSize 0 must be at least 1; using 1000",
        "sessionIdleTimeout 0.0004 must be at least 0.001s; using 1800s",
        "sessionMaxDuration -5.0 must be at least 0.001s; using 86400s",
      ]
    )
  }

  @Test("durations that are not finite or do not fit are replaced by their defaults")
  func unusableDurations() throws {
    var options = Pug.Options(apiKey: "pub_test")
    options.batchMaxWait = .nan
    options.sessionIdleTimeout = .infinity
    options.sessionMaxDuration = 1e300

    let configuration = try Configuration(projectId: Self.project, options: options)

    #expect(configuration.batchMaxWaitMillis == 5_000)
    #expect(configuration.sessionIdleTimeoutMillis == 30 * 60_000)
    #expect(configuration.sessionMaxDurationMillis == 24 * 60 * 60_000)
    #expect(
      configuration.warnings == [
        "batchMaxWait nan is not a usable number of seconds; using 5s",
        "sessionIdleTimeout inf is not a usable number of seconds; using 1800s",
        "sessionMaxDuration 1e+300 is not a usable number of seconds; using 86400s",
      ]
    )
  }

  @Test("a batch size above the server's limit is capped rather than reset")
  func batchSizeCap() throws {
    var options = Pug.Options(apiKey: "pub_test")
    options.batchMaxSize = 5_000

    let configuration = try Configuration(projectId: Self.project, options: options)

    #expect(configuration.batchMaxSize == 1_000)
    #expect(configuration.warnings == ["batchMaxSize 5000 is above the server's limit; using 1000"])
  }

  @Test("a blank project id or API key is refused")
  func blank() {
    expectRefused("Pug.initialize() needs a project id", projectId: " ")
    expectRefused("Pug.initialize() needs a project id", projectId: "")
    expectRefused("Pug.initialize() needs an API key", options: Pug.Options(apiKey: " "))
  }

  @Test("an API key that is not a public key is refused")
  func notPublicKey() {
    for apiKey in ["prv_0123456789abcdef0123", Self.project, "PUB_0123456789abcdef0123"] {
      expectRefused(
        "Pug.initialize() needs a public API key (pub_…), not a private key or the project id",
        options: Pug.Options(apiKey: apiKey)
      )
    }
  }

  @Test("an API key with spaces, control characters or non-ASCII is refused")
  func unprintableKey() throws {
    for apiKey in ["pub_test\n", " pub_test", "pub_te st", "pub_tëst", "pub_\u{0}"] {
      expectRefused(
        "The Pug API key must be printable ASCII without spaces (check for a trailing newline)",
        options: Pug.Options(apiKey: apiKey)
      )
    }
    _ = try Configuration(projectId: Self.project, options: Pug.Options(apiKey: "pub_0123456789abcdef0123"))
  }

  @Test("an endpoint that is not an http(s) URL with a host is refused")
  func endpoint() throws {
    let refused = [
      try #require(URL(string: "api.pugs.dev")),
      try #require(URL(string: "ftp://api.pugs.dev")),
      try #require(URL(string: "https://")),
      URL(fileURLWithPath: "/tmp"),
    ]
    for endpoint in refused {
      var options = Pug.Options(apiKey: "pub_test")
      options.endpoint = endpoint
      expectRefused("The Pug endpoint must be an http(s) URL, not \"\(endpoint.absoluteString)\"", options: options)
    }
    for accepted in ["http://10.0.2.2:8080/", "HTTPS://API.PUGS.DEV"] {
      var options = Pug.Options(apiKey: "pub_test")
      options.endpoint = try #require(URL(string: accepted))
      _ = try Configuration(projectId: Self.project, options: options)
    }
  }

  @Test("an endpoint with a query or a fragment is refused, since the calls' paths would land in it")
  func endpointQuery() throws {
    for refused in ["https://proxy.example.com/pug?tenant=a", "https://proxy.example.com/pug#a"] {
      var options = Pug.Options(apiKey: "pub_test")
      options.endpoint = try #require(URL(string: refused))
      expectRefused("The Pug endpoint must have no query or fragment: \"\(refused)\"", options: options)
    }
  }

  private func expectRefused(
    _ message: String,
    projectId: String = ConfigurationTests.project,
    options: Pug.Options = Pug.Options(apiKey: "pub_test"),
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(throws: Pug.ConfigurationError(message), sourceLocation: sourceLocation) {
      try Configuration(projectId: projectId, options: options)
    }
  }
}
