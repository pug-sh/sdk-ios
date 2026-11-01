/// The persisted form of a queued event, in the family's domain shape: values are tagged `{"stringValue": ...}`,
/// `{"intValue": ...}` and so on, and times are epoch milliseconds.
enum EventJSON {
    static func encode(_ event: Event) -> String {
        let json = JSONWriter(capacity: 256)
            .beginObject()
            .name("eventId").value(event.eventId)
            .name("kind").value(event.kind)
            .name("sessionId").value(event.sessionId)
            .name("distinctId").value(event.distinctId)
            .name("occurTime").value(event.occurTimeMillis)
        write(event.customProperties, named: "customProperties", to: json)
        write(event.autoProperties, named: "autoProperties", to: json)
        return json.endObject().text
    }

    /// The event in `json`, an element of what `StoredJSON.parse` read, or nil when it is incomplete or would fail
    /// the server's validation: one such event would get its whole batch rejected.
    static func decode(_ json: Any) -> Event? {
        guard let object = json as? [String: Any],
            let eventId = object["eventId"] as? String, eventId.isUUID,
            let kind = object["kind"] as? String, kind.isValidKind,
            let sessionId = object["sessionId"] as? String, sessionId.isUUID,
            let distinctId = object["distinctId"] as? String, !distinctId.isEmpty,
            let occurTime = StoredJSON.int64(object["occurTime"]), Limits.occurTimeMillis.contains(occurTime),
            let autoProperties = properties(object["autoProperties"], auto: true),
            let customProperties = properties(object["customProperties"], auto: false)
        else { return nil }
        return Event(
            eventId: eventId,
            kind: kind,
            distinctId: distinctId,
            sessionId: sessionId,
            occurTimeMillis: occurTime,
            autoProperties: autoProperties,
            customProperties: customProperties
        )
    }

    private static func write(_ properties: [String: PropertyValue], named name: String, to json: JSONWriter) {
        json.name(name).beginObject()
        for (key, value) in properties.sortedByUTF16Key() {
            json.name(key).beginObject()
            switch value {
            case .string(let string):
                json.name("stringValue").value(string)
            case .int(let int):
                json.name("intValue").value(int)
            case .double(let double):
                json.name("doubleValue").value(double)
            case .bool(let bool):
                json.name("boolValue").value(bool)
            case .timestamp(let epochMillis):
                json.name("timestampValue").value(epochMillis)
            }
            json.endObject()
        }
        json.endObject()
    }

    private static func properties(_ json: Any?, auto: Bool) -> [String: PropertyValue]? {
        guard let object = json as? [String: Any] else { return nil }
        var properties: [String: PropertyValue] = [:]
        for (key, value) in object {
            guard key.hasUTF8Prefix("$") == auto, let value = propertyValue(value) else { return nil }
            properties[key] = value
        }
        return properties
    }

    private static func propertyValue(_ json: Any) -> PropertyValue? {
        guard let tagged = json as? [String: Any], tagged.count == 1, let (tag, value) = tagged.first else {
            return nil
        }
        switch tag {
        case "stringValue":
            guard let string = value as? String, string.utf8.count <= Limits.maxStringBytes else { return nil }
            return .string(string)
        case "intValue":
            return StoredJSON.int64(value).map(PropertyValue.int)
        case "doubleValue":
            guard let double = StoredJSON.double(value), double.isFinite else { return nil }
            return .double(double)
        case "boolValue":
            return StoredJSON.bool(value).map(PropertyValue.bool)
        case "timestampValue":
            guard let millis = StoredJSON.int64(value), Limits.timestampMillis.contains(millis) else { return nil }
            return .timestamp(epochMillis: millis)
        default:
            return nil
        }
    }
}
