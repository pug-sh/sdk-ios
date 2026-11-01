import Testing

@testable import Pug

struct ProtoWriterTests {
    @Test("varints use the protobuf encoding")
    func varints() {
        #expect(write { $0.writeInt64(field: 1, 0) } == [0x08, 0x00])
        #expect(write { $0.writeInt64(field: 1, 1) } == [0x08, 0x01])
        #expect(write { $0.writeInt64(field: 1, 127) } == [0x08, 0x7F])
        #expect(write { $0.writeInt64(field: 1, 128) } == [0x08, 0x80, 0x01])
        #expect(write { $0.writeInt64(field: 1, 300) } == [0x08, 0xAC, 0x02])
        #expect(
            write { $0.writeInt64(field: 1, -1) } == [0x08, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]
        )
        #expect(
            write { $0.writeInt64(field: 1, .min) } == [
                0x08, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01,
            ]
        )
    }

    @Test("varint sizes match what the writer writes")
    func varintSizes() {
        var values: [UInt64] = [0, .max]
        for bit in 0..<64 {
            values += [1 << bit, (1 << bit) - 1, (1 << bit) + 1]
        }

        for value in values {
            let written = write { $0.writeInt64(field: 1, Int64(bitPattern: value)) }
            #expect(varintSize(value) == written.count - 1, "\(value)")
        }
    }

    @Test("negative int32 sign-extends to ten bytes")
    func negativeInt32() {
        #expect(
            write { $0.writeInt32(field: 2, -1) } == [0x10, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]
        )
    }

    @Test("tags carry the field number and wire type")
    func tags() {
        #expect(write { $0.writeBool(field: 127, true) } == [0xF8, 0x07, 0x01])
        #expect(write { $0.writeBool(field: 128, false) } == [0x80, 0x08, 0x00])
        #expect(write { $0.writeBool(field: 536_870_911, true) } == [0xF8, 0xFF, 0xFF, 0xFF, 0x0F, 0x01])
    }

    @Test("doubles are little-endian fixed64")
    func doubles() {
        #expect(write { $0.writeDouble(field: 3, 1.5) } == [0x19, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF8, 0x3F])
    }

    @Test("strings are length-prefixed UTF-8")
    func strings() {
        #expect(write { $0.writeString(field: 1, "\u{20AC}") } == [0x0A, 0x03, 0xE2, 0x82, 0xAC])
        #expect(write { $0.writeString(field: 1, "") } == [0x0A, 0x00])
    }

    // Swift strings are always valid Unicode: one built from a lone surrogate holds U+FFFD instead.
    @Test("a string decoded from a lone surrogate encodes as valid UTF-8")
    func loneSurrogate() throws {
        let string = String(decoding: [0x61, 0xD800, 0x62] as [UInt16], as: UTF16.self)

        let encoded = write { $0.writeString(field: 1, string) }

        #expect(encoded == [0x0A, 0x05, 0x61, 0xEF, 0xBF, 0xBD, 0x62])
    }

    @Test("nested messages are length-prefixed")
    func nestedMessages() {
        var inner = ProtoWriter()
        inner.writeInt64(field: 1, 150)

        #expect(write { $0.writeMessage(field: 3, inner) } == [0x1A, 0x03, 0x08, 0x96, 0x01])
    }

    @Test("the buffer grows past its initial capacity")
    func growth() {
        let long = String(repeating: "x", count: 10_000)

        let encoded = write { $0.writeString(field: 1, long) }

        #expect(encoded.count == 10_003)
        #expect(encoded.dropFirst(3).allSatisfy { $0 == UInt8(ascii: "x") })
    }

    @Test("the reader round-trips what the writer wrote")
    func roundTrip() throws {
        let encoded = write {
            $0.writeInt64(field: 1, .min)
            $0.writeString(field: 2, "pug")
            $0.writeDouble(field: 3, 2.5)
        }

        var reader = ProtoReader(encoded)
        #expect(try reader.readTag() == 1 << 3 | WireType.varint.rawValue)
        #expect(try reader.readVarint() == UInt64(bitPattern: .min))
        #expect(try reader.readTag() == 2 << 3 | WireType.len.rawValue)
        #expect(try reader.readString() == "pug")
        #expect(try reader.readTag() == 3 << 3 | WireType.i64.rawValue)
        try reader.skip(wireType: WireType.i64.rawValue)
        #expect(reader.isAtEnd)
    }

    private func write(_ body: (inout ProtoWriter) -> Void) -> [UInt8] {
        var writer = ProtoWriter()
        body(&writer)
        return writer.bytes
    }
}
