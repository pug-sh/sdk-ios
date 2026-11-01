import Foundation
import Testing

@testable import Pug

struct IdsTests {
    @Test("ids are version 7 UUIDs led by the clock's milliseconds")
    func versionSeven() throws {
        let generator = UUIDv7Generator(clock: FixedClock(nowMillis: 0x0192_F3A4_1B2C))

        let id = generator.nextId()

        #expect(id.isUUID)
        #expect(id.hasPrefix("0192f3a4-1b2c-7"))
        #expect(id == id.lowercased())
        let uuid = try #require(UUID(uuidString: id)).uuid
        #expect(uuid.6 >> 4 == 7)
        #expect(uuid.8 >> 6 == 0b10)
    }

    @Test("the version and variant bits hold whatever the random bits are")
    func versionAndVariantBits() {
        let clock = FixedClock(nowMillis: 0x0192_F3A4_1B2C)

        #expect(UUIDv7Generator(clock: clock, random: { 0 }).nextId() == "0192f3a4-1b2c-7000-8000-000000000000")
        #expect(UUIDv7Generator(clock: clock, random: { .max }).nextId() == "0192f3a4-1b2c-7fff-bfff-ffffffffffff")
    }

    @Test("the timestamp is the clock's low 48 bits")
    func timestampBits() {
        let generator = UUIDv7Generator(clock: FixedClock(nowMillis: -1), random: { 0 })

        #expect(generator.nextId() == "ffffffff-ffff-7000-8000-000000000000")
    }

    @Test("ids differ within one millisecond")
    func unique() {
        let generator = UUIDv7Generator(clock: FixedClock())

        let ids = (0..<1_000).map { _ in generator.nextId() }

        #expect(Set(ids).count == ids.count)
    }

    @Test("isUUID follows the server's string.uuid rule")
    func isUUIDRule() {
        #expect("0192f3a4-1b2c-7d3e-8f40-5a6b7c8d9e0f".isUUID)
        #expect("0192F3A4-1B2C-7D3E-8F40-5A6B7C8D9E0F".isUUID)
        #expect(!"".isUUID)
        #expect(!"0192f3a4-1b2c-7d3e-8f40-5a6b7c8d9e0".isUUID)
        #expect(!"0192f3a4-1b2c-7d3e-8f40-5a6b7c8d9e0ff".isUUID)
        #expect(!"0192f3a41b2c-7d3e-8f40-5a6b7c8d9e0f-".isUUID)
        #expect(!"0192f3a4-1b2c-7d3e-8f40-5a6b7c8d9e0g".isUUID)
        #expect(!"anon-0192f3a4-1b2c-7d3e-8f40-5a6b7c8".isUUID)
        #expect(!"0192f3a4-1b2c-7d3e-8f40-5a6b7c8d9\u{E9}".isUUID)
    }
}
