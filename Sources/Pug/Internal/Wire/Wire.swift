// Field numbers mirror proto/sdk/events/v1/events.proto, proto/sdk/profiles/v1/profiles.proto,
// proto/common/v1/property_value.proto and google/protobuf/{timestamp,struct}.proto. Map entries are
// written in UTF-16 key order, which is what protobuf-java's deterministic serialization produces.
enum Wire {
    static func encodeBatchCreateRequest(_ events: [Event]) -> [UInt8] {
        var request = ProtoWriter(capacity: 512 * min(events.count, 1_000))
        for event in events {
            request.writeMessage(field: 1, eventMessage(event))
        }
        return request.bytes
    }

    static func encodeIdentifyRequest(_ request: IdentifyRequest) -> [UInt8] {
        var message = ProtoWriter()
        message.writeString(field: 1, request.externalId)
        if !request.traits.isEmpty {
            message.writeMessage(field: 2, structMessage(request.traits))
        }
        if let anonymousId = request.anonymousId, !anonymousId.isEmpty {
            message.writeString(field: 3, anonymousId)
        }
        return message.bytes
    }

    /// Bytes `event` adds to an encoded `BatchCreateRequest`: its tag, length prefix and message.
    static func eventSize(_ event: Event) -> Int {
        lengthDelimitedSize(field: 1, eventMessageSize(event))
    }

    static func decodeBatchCreateResponse(_ bytes: [UInt8]) throws -> BatchCreateResponse {
        var reader = ProtoReader(bytes)
        var accepted: Int64 = 0
        var droppedByReason: [String: Int64] = [:]
        while !reader.isAtEnd {
            let tag = try reader.readTag()
            switch tag {
            case key(1, .varint):
                accepted = uint32(try reader.readVarint())
            case key(3, .len):
                var entry = try reader.readMessage()
                var reason = ""
                var count: Int64 = 0
                while !entry.isAtEnd {
                    let entryTag = try entry.readTag()
                    switch entryTag {
                    case key(1, .len):
                        reason = try entry.readString()
                    case key(2, .varint):
                        count = uint32(try entry.readVarint())
                    default:
                        try entry.skip(wireType: entryTag & 7)
                    }
                }
                droppedByReason[reason] = count
            default:
                try reader.skip(wireType: tag & 7)
            }
        }
        return BatchCreateResponse(accepted: accepted, droppedByReason: droppedByReason)
    }

    // Edition 2023 gives singular fields explicit presence, so an empty id would be sent as a set
    // field and fail the server's uuid rule; empty means "absent" in the domain model.
    private static func eventMessage(_ event: Event) -> ProtoWriter {
        var message = ProtoWriter(capacity: 256)
        message.writeStringIfNotEmpty(field: 1, event.eventId)
        message.writeSortedMap(field: 2, event.autoProperties, propertyValue)
        message.writeSortedMap(field: 3, event.customProperties, propertyValue)
        message.writeStringIfNotEmpty(field: 4, event.distinctId)
        message.writeStringIfNotEmpty(field: 5, event.kind)
        message.writeMessage(field: 6, timestamp(event.occurTimeMillis))
        message.writeStringIfNotEmpty(field: 7, event.sessionId)
        return message
    }

    // A selected oneof member is written even when it holds the default value: without it the
    // PropertyValue is empty, which the server's oneof.required rule rejects for the whole batch.
    private static func propertyValue(_ value: PropertyValue) -> ProtoWriter {
        var message = ProtoWriter(capacity: 16)
        switch value {
        case .string(let string):
            message.writeString(field: 1, string)
        case .int(let int):
            message.writeInt64(field: 2, int)
        case .double(let double):
            message.writeDouble(field: 3, double)
        case .bool(let bool):
            message.writeBool(field: 4, bool)
        case .timestamp(let epochMillis):
            message.writeMessage(field: 5, timestamp(epochMillis))
        }
        return message
    }

    private static func timestamp(_ epochMillis: Int64) -> ProtoWriter {
        let (seconds, nanos) = secondsAndNanos(epochMillis)
        var message = ProtoWriter(capacity: 16)
        if seconds != 0 {
            message.writeInt64(field: 1, seconds)
        }
        if nanos != 0 {
            message.writeInt32(field: 2, nanos)
        }
        return message
    }

    // Floored, since a Timestamp's nanos are never negative, before 1970 included.
    private static func secondsAndNanos(_ epochMillis: Int64) -> (seconds: Int64, nanos: Int32) {
        let (quotient, remainder) = epochMillis.quotientAndRemainder(dividingBy: 1_000)
        let floored = remainder < 0 ? (quotient - 1, remainder + 1_000) : (quotient, remainder)
        return (floored.0, Int32(truncatingIfNeeded: floored.1) * 1_000_000)
    }

    private static func structMessage(_ fields: [String: JSONValue]) -> ProtoWriter {
        var message = ProtoWriter()
        message.writeSortedMap(field: 1, fields, value)
        return message
    }

    private static func value(_ value: JSONValue) -> ProtoWriter {
        var message = ProtoWriter(capacity: 16)
        switch value {
        case .null:
            message.writeInt32(field: 1, 0)
        case .number(let number):
            message.writeDouble(field: 2, number)
        case .string(let string):
            message.writeString(field: 3, string)
        case .bool(let bool):
            message.writeBool(field: 4, bool)
        case .object(let fields):
            message.writeMessage(field: 5, structMessage(fields))
        case .array(let elements):
            var list = ProtoWriter()
            for element in elements {
                list.writeMessage(field: 1, Wire.value(element))
            }
            message.writeMessage(field: 6, list)
        }
        return message
    }

    // Mirrors eventMessage(_:) field by field without allocating; WireTests pins it to the encoder.
    private static func eventMessageSize(_ event: Event) -> Int {
        var size = 0
        size += stringSizeIfNotEmpty(field: 1, event.eventId)
        size += propertyMapSize(field: 2, event.autoProperties)
        size += propertyMapSize(field: 3, event.customProperties)
        size += stringSizeIfNotEmpty(field: 4, event.distinctId)
        size += stringSizeIfNotEmpty(field: 5, event.kind)
        size += lengthDelimitedSize(field: 6, timestampSize(event.occurTimeMillis))
        size += stringSizeIfNotEmpty(field: 7, event.sessionId)
        return size
    }

    private static func propertyMapSize(field: UInt32, _ properties: [String: PropertyValue]) -> Int {
        var size = 0
        for (key, value) in properties {
            let entry = stringSize(field: 1, key) + lengthDelimitedSize(field: 2, propertyValueSize(value))
            size += lengthDelimitedSize(field: field, entry)
        }
        return size
    }

    private static func propertyValueSize(_ value: PropertyValue) -> Int {
        switch value {
        case .string(let string):
            return stringSize(field: 1, string)
        case .int(let int):
            return tagSize(field: 2) + varintSize(UInt64(bitPattern: int))
        case .double:
            return tagSize(field: 3) + 8
        case .bool:
            return tagSize(field: 4) + 1
        case .timestamp(let epochMillis):
            return lengthDelimitedSize(field: 5, timestampSize(epochMillis))
        }
    }

    private static func timestampSize(_ epochMillis: Int64) -> Int {
        let (seconds, nanos) = secondsAndNanos(epochMillis)
        var size = 0
        if seconds != 0 {
            size += tagSize(field: 1) + varintSize(UInt64(bitPattern: seconds))
        }
        if nanos != 0 {
            size += tagSize(field: 2) + varintSize(UInt64(bitPattern: Int64(nanos)))
        }
        return size
    }

    private static func stringSizeIfNotEmpty(field: UInt32, _ value: String) -> Int {
        value.isEmpty ? 0 : stringSize(field: field, value)
    }

    private static func stringSize(field: UInt32, _ value: String) -> Int {
        lengthDelimitedSize(field: field, value.utf8.count)
    }

    private static func lengthDelimitedSize(field: UInt32, _ length: Int) -> Int {
        tagSize(field: field) + varintSize(UInt64(length)) + length
    }

    private static func tagSize(field: UInt32) -> Int {
        varintSize(UInt64(field) << 3)
    }

    private static func key(_ field: UInt32, _ wireType: WireType) -> UInt32 {
        field << 3 | wireType.rawValue
    }

    private static func uint32(_ varint: UInt64) -> Int64 {
        Int64(UInt32(truncatingIfNeeded: varint))
    }
}

extension ProtoWriter {
    fileprivate mutating func writeStringIfNotEmpty(field: UInt32, _ value: String) {
        if !value.isEmpty {
            writeString(field: field, value)
        }
    }

    fileprivate mutating func writeSortedMap<Value>(
        field: UInt32,
        _ map: [String: Value],
        _ value: (Value) -> ProtoWriter
    ) {
        for (key, element) in map.sortedByUTF16Key() {
            var entry = ProtoWriter()
            entry.writeString(field: 1, key)
            entry.writeMessage(field: 2, value(element))
            writeMessage(field: field, entry)
        }
    }
}
