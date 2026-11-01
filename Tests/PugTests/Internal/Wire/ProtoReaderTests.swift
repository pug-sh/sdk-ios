import Testing

@testable import Pug

struct ProtoReaderTests {
    @Test("malformed varints are rejected")
    func malformedVarints() {
        expectFailure([0x80]) { try $0.readVarint() }
        expectFailure([UInt8](repeating: 0x80, count: 11)) { try $0.readVarint() }
        expectFailure([UInt8](repeating: 0xFF, count: 10) + [0x01]) { try $0.readVarint() }
        expectFailure([]) { try $0.readVarint() }
    }

    @Test("a tenth varint byte keeps only its lowest bit, as protobuf-java reads it")
    func tenthVarintByte() throws {
        var reader = ProtoReader([UInt8](repeating: 0xFF, count: 9) + [0x7F])

        #expect(try reader.readVarint() == .max)
        #expect(reader.isAtEnd)
    }

    @Test("invalid tags are rejected")
    func invalidTags() {
        // Field number 0, with each wire type.
        for tag: UInt8 in 0..<8 {
            expectFailure([tag]) { try $0.readTag() }
        }
        // A tag beyond 32 bits.
        expectFailure([0x80, 0x80, 0x80, 0x80, 0x10]) { try $0.readTag() }
        expectFailure([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]) { try $0.readTag() }
    }

    @Test("the largest field number is a valid tag")
    func largestFieldNumber() throws {
        var reader = ProtoReader([0xF8, 0xFF, 0xFF, 0xFF, 0x0F])

        #expect(try reader.readTag() == 536_870_911 << 3)
    }

    @Test("lengths past the end of the input are rejected, however large")
    func lengths() {
        expectFailure([0x05, 0x61]) { try $0.readString() }
        expectFailure([0x01]) { try $0.readMessage() }
        expectFailure([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01, 0x61]) { try $0.readString() }
        expectFailure([0xFF, 0xFF, 0xFF, 0xFF, 0x07, 0x61]) { try $0.readMessage() }
        expectFailure([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F]) {
            try $0.skip(wireType: WireType.len.rawValue)
        }
    }

    @Test("a nested message ends at its own length, not at the end of the input")
    func nestedLimit() throws {
        var reader = ProtoReader([0x02, 0x0A, 0x05, 0x61, 0x62, 0x63, 0x64, 0x65])

        var message = try reader.readMessage()

        #expect(try message.readTag() == 1 << 3 | WireType.len.rawValue)
        #expect(throws: ProtoDecodeError.self) { try message.readString() }
        #expect(!reader.isAtEnd)
    }

    @Test("fixed-width fields past the end of the input are rejected")
    func fixedWidth() {
        expectFailure([0x01, 0x02]) { try $0.skip(wireType: WireType.i64.rawValue) }
        expectFailure([0x01, 0x02, 0x03]) { try $0.skip(wireType: WireType.i32.rawValue) }
        expectFailure([0x80]) { try $0.skip(wireType: WireType.varint.rawValue) }
    }

    @Test("groups and unknown wire types are rejected")
    func unsupportedWireTypes() {
        for wireType: UInt32 in [3, 4, 6, 7] {
            expectFailure([0x01]) { try $0.skip(wireType: wireType) }
        }
    }

    @Test("invalid UTF-8 decodes with replacement characters, as on Android")
    func invalidUTF8() throws {
        var reader = ProtoReader([0x04, 0x61, 0xFF, 0xC3, 0x62])

        #expect(try reader.readString() == "a\u{FFFD}\u{FFFD}b")
    }

    private func expectFailure<T>(
        _ bytes: [UInt8],
        sourceLocation: SourceLocation = #_sourceLocation,
        _ read: (inout ProtoReader) throws -> T
    ) {
        var reader = ProtoReader(bytes)
        #expect(throws: ProtoDecodeError.self, sourceLocation: sourceLocation) { _ = try read(&reader) }
    }
}
