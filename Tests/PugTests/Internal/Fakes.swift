@testable import Pug

final class RecordingLogger: Pug.Logger {
    struct Entry: Sendable {
        let level: String
        let message: String
        let error: (any Error)?
    }

    private let recorded = Locked<[Entry]>([])

    var entries: [Entry] {
        recorded.withLock { $0 }
    }

    var debugs: [String] {
        messages("debug")
    }

    var warnings: [String] {
        messages("warning")
    }

    var errors: [String] {
        messages("error")
    }

    func debug(_ message: String) {
        record("debug", message, nil)
    }

    func warning(_ message: String, error: (any Error)?) {
        record("warning", message, error)
    }

    func error(_ message: String, error: (any Error)?) {
        record("error", message, error)
    }

    func safe(debug: Bool = true) -> SafeLogger {
        SafeLogger(self, isDebugEnabled: debug)
    }

    private func record(_ level: String, _ message: String, _ error: (any Error)?) {
        recorded.withLock { $0.append(Entry(level: level, message: message, error: error)) }
    }

    private func messages(_ level: String) -> [String] {
        entries.filter { $0.level == level }.map(\.message)
    }
}

struct FixedClock: Clock {
    var nowMillis: Int64 = 1_760_000_000_000
}

/// Valid, predictable UUIDs: `00000000-0000-7000-8000-000000000001`, then ...02, and so on.
final class SequentialIds: IdGenerator {
    private let count = Locked(0)

    func nextId() -> String {
        let next = count.withLock { count in
            count += 1
            return count
        }
        let digits = String(next, radix: 16)
        return "00000000-0000-7000-8000-" + String(repeating: "0", count: max(12 - digits.count, 0)) + digits
    }
}

/// SplitMix64: a seeded generator, so randomized tests fail the same way every run.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
