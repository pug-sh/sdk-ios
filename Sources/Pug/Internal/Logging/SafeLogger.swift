import Foundation

#if canImport(os)
import os
#endif

/// The only logger the SDK calls: debug messages are dropped, unbuilt, unless debug logging is on.
/// Swift cannot catch a trap, so unlike Android's, it cannot contain a host logger that crashes.
struct SafeLogger: Sendable {
    let isDebugEnabled: Bool
    private let delegate: any Pug.Logger

    init(_ delegate: any Pug.Logger, isDebugEnabled: Bool) {
        self.delegate = delegate
        self.isDebugEnabled = isDebugEnabled
    }

    func debug(_ message: @autoclosure () -> String) {
        if isDebugEnabled {
            delegate.debug(message())
        }
    }

    func warning(_ message: String, error: (any Error)? = nil) {
        delegate.warning(message, error: error)
    }

    func error(_ message: String, error: (any Error)? = nil) {
        delegate.error(message, error: error)
    }
}

/// The default logger: the unified log (subsystem `sh.pug`, category `Pug`), or stderr where there
/// is none. The unified log redacts dynamic strings, so lines are marked public: they never hold
/// properties or traits.
struct SystemLogger: Pug.Logger {
    private enum Level {
        case debug
        case warning
        case error
    }

    func debug(_ message: String) {
        emit(.debug, message)
    }

    func warning(_ message: String, error: (any Error)?) {
        emit(.warning, line(message, error))
    }

    func error(_ message: String, error: (any Error)?) {
        emit(.error, line(message, error))
    }

    private func line(_ message: String, _ error: (any Error)?) -> String {
        guard let error else { return message }
        return "\(message): \(error)"
    }

    private func emit(_ level: Level, _ line: String) {
        #if canImport(os)
        let log = os.Logger(subsystem: "sh.pug", category: "Pug")
        switch level {
        case .debug:
            log.debug("\(line, privacy: .public)")
        case .warning:
            log.warning("\(line, privacy: .public)")
        case .error:
            log.error("\(line, privacy: .public)")
        }
        #else
        try? FileHandle.standardError.write(contentsOf: Data("Pug \(level): \(line)\n".utf8))
        #endif
    }
}
