import Testing

@testable import Pug

struct PugTests {
  @Test("the options default to the family's")
  func defaultOptions() {
    let options = Pug.Options(apiKey: "pub_test")

    #expect(options.apiKey == "pub_test")
    #expect(options.endpoint.absoluteString == "https://api.pugs.dev")
    #expect(!options.debug)
    #expect(!options.dryRun)
    #expect(options.batchMaxSize == 10)
    #expect(options.batchMaxWait == 5)
    #expect(options.batchMaxQueueSize == 1_000)
    #expect(options.sessionIdleTimeout == 30 * 60)
    #expect(options.sessionMaxDuration == 24 * 60 * 60)
    #expect(options.defaultTrackingConsent == .granted)
    #expect(options.persistTrackingConsent)
    #expect(options.autoOpenCloseEvents)
    #expect(options.autoScreenViews)
    #expect(options.autoInstallEvents)
    #expect(options.logger == nil)
    #expect(options.storage == nil)
  }

  @Test("initialize throws a ConfigurationError that says what to fix")
  func configurationError() {
    do {
      try Pug.initialize(projectId: " ", options: Pug.Options(apiKey: "pub_test"))
      Issue.record("initialize accepted a blank project id")
    } catch {
      #expect(error.message == "Pug.initialize() needs a project id")
      #expect(error.description == error.message)
      #expect(error.localizedDescription == error.message)
    }
  }
}
