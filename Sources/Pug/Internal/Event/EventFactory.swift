import Foundation

extension String {
    /// The server's `Event.kind` pattern, `^[a-zA-Z0-9_.-]+$`.
    var isValidKind: Bool {
        !isEmpty
            && utf8.allSatisfy { byte in
                switch byte {
                case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                    UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "-"):
                    return true
                default:
                    return false
                }
            }
    }
}

struct EventFactory: Sendable {
    static let platform = "ios"

    let projectId: String
    let logger: SafeLogger
    let properties: PropertyMapper
    let ids: any IdGenerator

    /// Logs and returns false for a kind the server would reject along with the rest of its batch.
    func acceptsKind(_ kind: String) -> Bool {
        if kind.isValidKind {
            return true
        }
        if kind.allSatisfy(\.isWhitespace) {
            logger.warning("An event with a blank kind was dropped")
        } else {
            logger.warning("Event \"\(kind)\" was dropped: a kind may only contain letters, digits, '_', '.' and '-'")
        }
        return false
    }

    /// `timestamp` when the caller set a usable one, else the time of the call.
    func occurTime(kind: String, timestamp: Date?, callTimeMillis: Int64) -> Int64 {
        guard let timestamp else { return callTimeMillis }
        let millis = timestamp.epochMillis
        if let millis, Limits.occurTimeMillis.contains(millis) {
            return millis
        }
        let time = millis.map { "\($0) ms" } ?? "\(timestamp.timeIntervalSince1970) s"
        logger.warning(
            "Event \"\(kind)\" has a timestamp outside 1970 to 9999 (\(time) since 1970); using the time of the call"
        )
        return callTimeMillis
    }

    /// Builds the event for an accepted `kind` from `customProperties` the caller mapped, or returns nil
    /// when it would not fit in a request. `$projectId`, `$sdkVersion` and `$platform` always come from
    /// the SDK.
    func create(
        kind: String,
        customProperties: [String: PropertyValue],
        autoProperties: [String: Any],
        distinctId: String,
        sessionId: String,
        occurTimeMillis: Int64
    ) -> Event? {
        var auto = properties.mapAuto(kind: kind, autoProperties)
        auto["$projectId"] = .string(projectId)
        auto["$sdkVersion"] = .string(sdkVersion)
        auto["$platform"] = .string(Self.platform)
        let event = Event(
            eventId: ids.nextId(),
            kind: kind,
            distinctId: distinctId,
            sessionId: sessionId,
            occurTimeMillis: occurTimeMillis,
            autoProperties: auto,
            customProperties: customProperties
        )
        let size = Wire.eventSize(event)
        if size > Limits.maxBatchBytes {
            logger.error(
                "Event \"\(kind)\" was dropped: it encodes to \(size) bytes, over the \(Limits.maxBatchBytes)-byte "
                    + "request limit"
            )
            return nil
        }
        return event
    }
}
