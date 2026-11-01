import Foundation
import SwiftProtobuf

@testable import Pug

/// The well-known events for iOS, read from events.binpb with swift-protobuf rather than through
/// Tools/gen-track, so the generated sources can be checked against the protos. The custom options
/// arrive as unknown fields.
enum EventProtos {
    struct Property: Equatable {
        let name: String
        let type: FieldSchema.ValueType
        let required: Bool
    }

    struct Event {
        let kind: String
        let properties: [Property]

        var method: String {
            let words = kind.split(separator: "_").map(String.init)
            return (words.first ?? "") + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        }
    }

    private static let kindOption: UInt32 = 50_000
    private static let platformsOption: UInt32 = 50_002
    private static let platformIOS: UInt64 = 2
    private static let fieldRulesOption: UInt32 = 1_159
    private static let requiredRule: UInt32 = 25

    static func ios() throws -> [Event] {
        guard let url = Bundle.module.url(forResource: "events", withExtension: "binpb") else {
            throw ProtoDecodeError("events.binpb is not among the test resources")
        }
        let descriptors = try Google_Protobuf_FileDescriptorSet(serializedBytes: Data(contentsOf: url))
        var events: [Event] = []
        for file in descriptors.file where file.package == "common.events.v1" {
            for message in file.messageType {
                let (kind, platforms) = try messageOptions(message.options.unknownFields.data)
                guard let kind, platforms.isEmpty || platforms.contains(platformIOS) else { continue }
                events.append(Event(kind: kind, properties: try message.field.map(property)))
            }
        }
        return events.sorted { $0.kind < $1.kind }
    }

    private static func property(_ field: Google_Protobuf_FieldDescriptorProto) throws -> Property {
        let type: FieldSchema.ValueType
        switch field.type {
        case .string:
            type = .string
        case .int32, .sint32, .sfixed32, .int64, .sint64, .sfixed64, .uint32, .fixed32:
            type = .int
        case .double, .float:
            type = .double
        case .bool:
            type = .bool
        case .message where field.typeName == ".google.protobuf.Duration":
            type = .duration
        default:
            throw ProtoDecodeError("unexpected type of \(field.name)")
        }
        return Property(name: field.jsonName, type: type, required: try isRequired(field.options.unknownFields.data))
    }

    private static func messageOptions(_ data: Data) throws -> (kind: String?, platforms: [UInt64]) {
        var reader = ProtoReader(Array(data))
        var kind: String?
        var platforms: [UInt64] = []
        while !reader.isAtEnd {
            let tag = try reader.readTag()
            switch (tag >> 3, tag & 7) {
            case (kindOption, 2):
                kind = try reader.readString()
            case (platformsOption, 0):
                platforms.append(try reader.readVarint())
            case (platformsOption, 2):
                var packed = try reader.readMessage()
                while !packed.isAtEnd {
                    platforms.append(try packed.readVarint())
                }
            default:
                try reader.skip(wireType: tag & 7)
            }
        }
        return (kind, platforms)
    }

    private static func isRequired(_ data: Data) throws -> Bool {
        var options = ProtoReader(Array(data))
        var required = false
        while !options.isAtEnd {
            let tag = try options.readTag()
            guard tag == fieldRulesOption << 3 | 2 else {
                try options.skip(wireType: tag & 7)
                continue
            }
            var rules = try options.readMessage()
            while !rules.isAtEnd {
                let ruleTag = try rules.readTag()
                if ruleTag == requiredRule << 3 {
                    required = try rules.readVarint() == 1
                } else {
                    try rules.skip(wireType: ruleTag & 7)
                }
            }
        }
        return required
    }
}
