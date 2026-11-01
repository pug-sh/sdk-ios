extension Pug {
    /// Receives the SDK's diagnostics in place of the system log. Calls may arrive on any thread, and
    /// debug messages only while debug logging is on. Messages never contain event properties or
    /// traits.
    public protocol Logger: Sendable {
        func debug(_ message: String)

        func warning(_ message: String, error: (any Error)?)

        func error(_ message: String, error: (any Error)?)
    }
}
