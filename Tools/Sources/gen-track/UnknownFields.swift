import Foundation

/// The fields of a message that its type does not declare, which is how custom options arrive.
struct UnknownFields {
    private var varints: [UInt32: [UInt64]] = [:]
    private var lengthDelimited: [UInt32: [UInt8]] = [:]

    init(_ data: Data) throws {
        var cursor = Cursor(bytes: Array(data))
        while !cursor.isAtEnd {
            let tag = try cursor.varint()
            let field = UInt32(truncatingIfNeeded: tag >> 3)
            switch tag & 7 {
            case 0:
                varints[field, default: []].append(try cursor.varint())
            case 1:
                _ = try cursor.take(8)
            case 2:
                let length = try cursor.varint()
                // A message option given twice merges, which is what parsing the bytes joined does.
                lengthDelimited[field, default: []].append(contentsOf: try cursor.take(length))
            case 5:
                _ = try cursor.take(4)
            default:
                throw CatalogError("unsupported wire type \(tag & 7) in options")
            }
        }
    }

    func string(_ field: UInt32) -> String? {
        lengthDelimited[field].map { String(decoding: $0, as: UTF8.self) }
    }

    func message(_ field: UInt32) throws -> UnknownFields? {
        try lengthDelimited[field].map { try UnknownFields(Data($0)) }
    }

    func bool(_ field: UInt32) -> Bool {
        varints[field]?.last == 1
    }

    /// Editions pack repeated enums, options included, so a repeated field may come either way.
    func repeatedVarints(_ field: UInt32) throws -> [UInt64] {
        var values = varints[field] ?? []
        var packed = Cursor(bytes: lengthDelimited[field] ?? [])
        while !packed.isAtEnd {
            values.append(try packed.varint())
        }
        return values
    }
}

private struct Cursor {
    let bytes: [UInt8]
    private var position = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    var isAtEnd: Bool {
        position >= bytes.count
    }

    mutating func varint() throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, to: 64, by: 7) {
            guard position < bytes.count else { throw CatalogError("truncated options") }
            let byte = bytes[position]
            position += 1
            value |= UInt64(byte & 0x7F) << UInt64(shift)
            if byte & 0x80 == 0 {
                return value
            }
        }
        throw CatalogError("a varint in options is too long")
    }

    mutating func take(_ count: UInt64) throws -> ArraySlice<UInt8> {
        guard count <= UInt64(bytes.count - position) else { throw CatalogError("truncated options") }
        let end = position + Int(count)
        defer { position = end }
        return bytes[position..<end]
    }
}
