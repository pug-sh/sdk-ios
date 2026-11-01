import Testing

@testable import Pug

struct SafeLoggerTests {
  private struct Failure: Error, Equatable {
    let reason: String
  }

  @Test("debug messages are delivered only when debug logging is on, and built only then")
  func debugGating() {
    let quiet = RecordingLogger()
    let verbose = RecordingLogger()
    let built = Locked(0)
    let message: @Sendable () -> String = {
      built.withLock { $0 += 1 }
      return "shown"
    }

    SafeLogger(quiet, isDebugEnabled: false).debug(message())
    SafeLogger(verbose, isDebugEnabled: true).debug(message())

    #expect(quiet.entries.isEmpty)
    #expect(verbose.debugs == ["shown"])
    #expect(built.withLock { $0 } == 1)
  }

  @Test("warnings and errors are always delivered with their error")
  func warningsAndErrors() throws {
    let delegate = RecordingLogger()
    let logger = SafeLogger(delegate, isDebugEnabled: false)

    logger.warning("careful")
    logger.error("broken", error: Failure(reason: "disk"))

    let entries = delegate.entries
    try #require(entries.map(\.level) == ["warning", "error"])
    #expect(entries.map(\.message) == ["careful", "broken"])
    #expect(entries[0].error == nil)
    #expect(entries[1].error as? Failure == Failure(reason: "disk"))
  }

  @Test("the system logger takes every level, with and without an error")
  func systemLogger() {
    let logger = SafeLogger(SystemLogger(), isDebugEnabled: true)

    logger.debug("SafeLoggerTests: debug")
    logger.warning("SafeLoggerTests: warning")
    logger.error("SafeLoggerTests: error", error: Failure(reason: "expected by the test"))
  }
}
