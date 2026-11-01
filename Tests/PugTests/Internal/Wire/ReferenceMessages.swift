import SwiftProtobuf

@testable import Pug

/// Builds the swift-protobuf equivalent of each domain model, field by field, so the hand-rolled
/// codec can be compared with a real protobuf implementation.
enum ReferenceMessages {
    static func batch(_ events: [Event]) -> Sdk_Events_V1_BatchCreateRequest {
        var request = Sdk_Events_V1_BatchCreateRequest()
        request.events = events.map(event)
        return request
    }

    static func identify(_ source: IdentifyRequest) -> Sdk_Profiles_V1_IdentifyRequest {
        var request = Sdk_Profiles_V1_IdentifyRequest()
        request.externalID = source.externalId
        if !source.traits.isEmpty {
            request.traits = structValue(source.traits)
        }
        if let anonymousId = source.anonymousId {
            request.anonymousID = anonymousId
        }
        return request
    }

    static func batchResponse(
        accepted: UInt32,
        dropped: UInt32,
        droppedByReason: [String: UInt32]
    ) -> Sdk_Events_V1_BatchCreateResponse {
        var response = Sdk_Events_V1_BatchCreateResponse()
        response.accepted = accepted
        response.dropped = dropped
        response.droppedByReason = droppedByReason
        return response
    }

    private static func event(_ source: Event) -> Sdk_Events_V1_Event {
        var event = Sdk_Events_V1_Event()
        event.eventID = source.eventId
        event.autoProperties = source.autoProperties.mapValues(propertyValue)
        event.customProperties = source.customProperties.mapValues(propertyValue)
        event.distinctID = source.distinctId
        event.kind = source.kind
        event.occurTime = timestamp(source.occurTimeMillis)
        event.sessionID = source.sessionId
        return event
    }

    private static func propertyValue(_ source: PropertyValue) -> Common_V1_PropertyValue {
        var message = Common_V1_PropertyValue()
        switch source {
        case .string(let string):
            message.stringValue = string
        case .int(let int):
            message.intValue = int
        case .double(let double):
            message.doubleValue = double
        case .bool(let bool):
            message.boolValue = bool
        case .timestamp(let epochMillis):
            message.timestampValue = timestamp(epochMillis)
        }
        return message
    }

    private static func timestamp(_ epochMillis: Int64) -> Google_Protobuf_Timestamp {
        var seconds = epochMillis / 1_000
        var millis = epochMillis % 1_000
        if millis < 0 {
            seconds -= 1
            millis += 1_000
        }
        return Google_Protobuf_Timestamp(seconds: seconds, nanos: Int32(millis) * 1_000_000)
    }

    private static func structValue(_ fields: [String: JSONValue]) -> Google_Protobuf_Struct {
        var message = Google_Protobuf_Struct()
        message.fields = fields.mapValues(value)
        return message
    }

    private static func value(_ source: JSONValue) -> Google_Protobuf_Value {
        var message = Google_Protobuf_Value()
        switch source {
        case .null:
            message.nullValue = .nullValue
        case .number(let number):
            message.numberValue = number
        case .string(let string):
            message.stringValue = string
        case .bool(let bool):
            message.boolValue = bool
        case .object(let fields):
            message.structValue = structValue(fields)
        case .array(let elements):
            message.listValue = Google_Protobuf_ListValue(values: elements.map(value))
        }
        return message
    }
}

extension SwiftProtobuf.Message {
    /// Map entries sorted by key as Swift's `<` orders them, which is the SDK's UTF-16 order unless a
    /// key holds a scalar beyond U+FFFF or is not in normalization form C.
    func deterministicBytes() throws -> [UInt8] {
        var options = BinaryEncodingOptions()
        options.useDeterministicOrdering = true
        return try serializedBytes(options: options)
    }
}
