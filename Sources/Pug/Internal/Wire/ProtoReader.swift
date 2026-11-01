struct ProtoDecodeError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

struct ProtoReader {
    private let bytes: [UInt8]
    private var position: Int
    private let limit: Int

    init(_ bytes: [UInt8]) {
        self.init(bytes, position: 0, limit: bytes.count)
    }

    private init(_ bytes: [UInt8], position: Int, limit: Int) {
        self.bytes = bytes
        self.position = position
        self.limit = limit
    }

    var isAtEnd: Bool {
        position >= limit
    }

    mutating func readTag() throws -> UInt32 {
        let value = try readVarint()
        guard let tag = UInt32(exactly: value), tag >> 3 != 0 else {
            throw ProtoDecodeError("invalid tag \(value)")
        }
        return tag
    }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while shift < 64 {
            let byte = try readByte()
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        throw ProtoDecodeError("varint longer than 10 bytes")
    }

    /// Invalid UTF-8 becomes U+FFFD rather than an error, as on Android.
    mutating func readString() throws -> String {
        let length = try readLength()
        let value = String(decoding: bytes[position..<position + length], as: UTF8.self)
        position += length
        return value
    }

    mutating func readMessage() throws -> ProtoReader {
        let length = try readLength()
        let message = ProtoReader(bytes, position: position, limit: position + length)
        position += length
        return message
    }

    mutating func skip(wireType: UInt32) throws {
        switch WireType(rawValue: wireType) {
        case .varint:
            _ = try readVarint()
        case .i64:
            try advance(8)
        case .len:
            try advance(readLength())
        case .i32:
            try advance(4)
        case nil:
            throw ProtoDecodeError("unsupported wire type \(wireType)")
        }
    }

    private mutating func readLength() throws -> Int {
        let length = try readVarint()
        guard length <= UInt64(clamping: limit - position) else {
            throw ProtoDecodeError("length \(length) exceeds remaining input")
        }
        return Int(length)
    }

    private mutating func advance(_ count: Int) throws {
        guard count <= limit - position else {
            throw ProtoDecodeError("field runs past the end of input")
        }
        position += count
    }

    private mutating func readByte() throws -> UInt8 {
        guard position < limit else {
            throw ProtoDecodeError("truncated input")
        }
        defer { position += 1 }
        return bytes[position]
    }
}
