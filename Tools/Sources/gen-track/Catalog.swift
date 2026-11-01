import Foundation
import SwiftProtobuf

struct CatalogError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

enum FieldType {
    case string
    case int
    case double
    case bool
    // Taken as a TimeInterval; the SDK sends options.proto's text form, such as "1.5s".
    case duration

    var swiftType: String {
        switch self {
        case .string: "String"
        case .int: "Int"
        case .double: "Double"
        case .bool: "Bool"
        case .duration: "TimeInterval"
        }
    }

    var schemaCase: String {
        switch self {
        case .string: ".string"
        case .int: ".int"
        case .double: ".double"
        case .bool: ".bool"
        case .duration: ".duration"
        }
    }
}

struct Field {
    let key: String
    let type: FieldType
    let required: Bool
    let pii: Bool
}

struct Event {
    let kind: String
    let comment: [String]
    let fields: [Field]

    /// The event's method on `Pug.track`, constant of `Pug.Events` and schema of `WellKnownEvents`.
    var name: String {
        let words = kind.split(separator: "_")
        return words.prefix(1).joined() + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }
}

private let eventsPackage = "common.events.v1"
// Extensions of common/events/v1/options.proto and buf/validate/validate.proto.
private let kindOption: UInt32 = 50_000
private let piiOption: UInt32 = 50_001
private let platformsOption: UInt32 = 50_002
private let fieldRulesOption: UInt32 = 1_159
private let requiredRule: UInt32 = 25
private let platformUnspecified: UInt64 = 0
private let platformIOS: UInt64 = 2
// FileDescriptorProto.message_type, as numbered in a SourceCodeInfo path.
private let messageTypePath = 4

private let swiftKeywords: Set<String> = [
    "Any", "Self", "_", "as", "associatedtype", "await", "borrowing", "break", "case", "catch", "class",
    "consuming", "continue", "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough",
    "false", "fileprivate", "for", "func", "guard", "if", "import", "in", "init", "inout", "internal", "is", "let",
    "nil", "nonisolated", "open", "operator", "precedencegroup", "private", "protocol", "public", "repeat",
    "rethrows", "return", "self", "static", "struct", "subscript", "super", "switch", "throw", "throws", "true",
    "try", "typealias", "var", "where", "while",
]
// Members of the generated types beside the events: TrackNamespace's facade, WellKnownEvents' lists.
private let reservedNames: Set<String> = ["facade", "all", "byKind"]
// Parameters every method takes, and the property the methods call.
private let reservedParameters: Set<String> = ["extras", "options", "facade"]

/// The well-known events for iOS in a protoc descriptor set: messages of `common.events.v1` with a
/// `kind` option, whose `platforms` option is unset or lists iOS. Sorted by kind.
func readEvents(from data: Data) throws -> [Event] {
    let descriptors = try Google_Protobuf_FileDescriptorSet(serializedBytes: data)
    var events: [String: Event] = [:]
    for file in descriptors.file where file.package == eventsPackage {
        let comments = leadingComments(file)
        for (index, message) in file.messageType.enumerated() {
            guard let event = try readEvent(message, comment: comments[[messageTypePath, index]]) else { continue }
            guard events.updateValue(event, forKey: event.kind) == nil else {
                throw CatalogError("kind \"\(event.kind)\" is declared twice")
            }
        }
    }
    if events.isEmpty {
        throw CatalogError("no well-known events in the descriptor set")
    }
    let sorted = events.values.sorted { $0.kind < $1.kind }
    try checkNames(sorted)
    return sorted
}

private func readEvent(_ message: Google_Protobuf_DescriptorProto, comment: String?) throws -> Event? {
    let options = try UnknownFields(message.options.unknownFields.data)
    guard let kind = options.string(kindOption), !kind.isEmpty else { return nil }
    let platforms = try options.repeatedVarints(platformsOption)
    if platforms.contains(platformUnspecified) {
        throw CatalogError("\(message.name) lists PLATFORM_UNSPECIFIED in its platforms")
    }
    if !platforms.isEmpty && !platforms.contains(platformIOS) {
        return nil
    }
    if kind.range(of: "^[a-z][a-z0-9]*(_[a-z0-9]+)*$", options: .regularExpression) == nil {
        throw CatalogError("\(message.name): kind \"\(kind)\" is not snake_case")
    }
    if !message.nestedType.isEmpty || !message.enumType.isEmpty || !message.oneofDecl.isEmpty {
        throw CatalogError("\(message.name): nested types, enums and oneofs are not supported")
    }
    let fields = try message.field.map { try readField(message.name, $0) }
    return Event(kind: kind, comment: comment.map(docLines) ?? [], fields: fields)
}

private func readField(_ message: String, _ field: Google_Protobuf_FieldDescriptorProto) throws -> Field {
    let location = "\(message).\(field.name)"
    if field.label == .repeated {
        throw CatalogError("\(location): repeated and map fields are not supported")
    }
    let type: FieldType
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
        throw CatalogError("\(location): fields of \(field.type) \(field.typeName) are not supported")
    }
    let options = try UnknownFields(field.options.unknownFields.data)
    let required = try options.message(fieldRulesOption)?.bool(requiredRule) ?? false
    return Field(key: field.jsonName, type: type, required: required, pii: options.bool(piiOption))
}

private func checkNames(_ events: [Event]) throws {
    var names: Set<String> = []
    for event in events {
        guard isUsable(event.name), !reservedNames.contains(event.name), names.insert(event.name).inserted else {
            throw CatalogError("kind \"\(event.kind)\" makes the name \(event.name), which is not usable")
        }
        var parameters = reservedParameters
        for field in event.fields {
            guard isUsable(field.key), parameters.insert(field.key).inserted else {
                throw CatalogError("\(event.kind).\(field.key) is not usable as a parameter name")
            }
        }
    }
}

private func isUsable(_ name: String) -> Bool {
    name.range(of: "^[a-z][A-Za-z0-9]*$", options: .regularExpression) != nil && !swiftKeywords.contains(name)
}

private func leadingComments(_ file: Google_Protobuf_FileDescriptorProto) -> [[Int]: String] {
    var comments: [[Int]: String] = [:]
    for location in file.sourceCodeInfo.location where location.hasLeadingComments {
        comments[location.path.map(Int.init)] = location.leadingComments
    }
    return comments
}

// The SDK's sources hold no em dashes, so a proto comment's become colons.
private func docLines(_ comment: String) -> [String] {
    var lines = comment.split(separator: "\n", omittingEmptySubsequences: false).map { line in
        var text = line.hasPrefix(" ") ? String(line.dropFirst()) : String(line)
        text = text.replacingOccurrences(of: "\\s*\u{2014}\\s*", with: ": ", options: .regularExpression)
        while text.last?.isWhitespace == true {
            text.removeLast()
        }
        return text
    }
    while lines.first?.isEmpty == true {
        lines.removeFirst()
    }
    while lines.last?.isEmpty == true {
        lines.removeLast()
    }
    return lines
}
