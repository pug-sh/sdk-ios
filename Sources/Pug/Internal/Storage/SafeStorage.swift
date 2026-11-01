/// Never throws. After the first failure of the primary store, every call goes to memory for the rest of the
/// client's life; components hold their state in memory and only write through, so nothing is lost until the
/// client is destroyed. Swift cannot catch a trap, so a store that traps still crashes.
final class SafeStorage {
    private let logger: SafeLogger
    private var active: any Pug.Storage

    /// Whether a failure moved storage to memory, which holds nothing from earlier launches.
    private(set) var hasFailedOver = false

    init(_ primary: any Pug.Storage, logger: SafeLogger) {
        active = primary
        self.logger = logger
    }

    // A fresh memory store holds nothing, so a failed read or remove has nothing to retry.
    func string(forKey key: String) -> String? {
        do {
            return try active.string(forKey: key)
        } catch {
            failOver(error)
            return nil
        }
    }

    func setString(_ value: String, forKey key: String) {
        do {
            try active.setString(value, forKey: key)
        } catch {
            if failOver(error) {
                setString(value, forKey: key)
            }
        }
    }

    func removeValue(forKey key: String) {
        do {
            try active.removeValue(forKey: key)
        } catch {
            failOver(error)
        }
    }

    @discardableResult
    private func failOver(_ failure: any Error) -> Bool {
        guard !hasFailedOver else { return false }
        hasFailedOver = true
        active = Pug.MemoryStorage()
        logger.warning("Storage failed; state is kept in memory only until the app restarts", error: failure)
        return true
    }
}
