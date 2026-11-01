protocol IdGenerator: Sendable {
    func nextId() -> String
}

/// RFC 9562 version 7: a 48-bit millisecond timestamp followed by 74 random bits.
struct UUIDv7Generator: IdGenerator {
    private let clock: any Clock
    private let random: @Sendable () -> UInt64

    init(clock: any Clock = SystemClock(), random: @escaping @Sendable () -> UInt64 = { .random(in: .min ... .max) }) {
        self.clock = clock
        self.random = random
    }

    func nextId() -> String {
        let millis = UInt64(bitPattern: clock.nowMillis)
        let high = (millis << 16) | 0x7000 | (random() & 0x0FFF)
        let low = 0x8000_0000_0000_0000 | (random() & 0x3FFF_FFFF_FFFF_FFFF)
        var id: [UInt8] = []
        id.reserveCapacity(36)
        for (index, byte) in (bigEndianBytes(high) + bigEndianBytes(low)).enumerated() {
            if index == 4 || index == 6 || index == 8 || index == 10 {
                id.append(UInt8(ascii: "-"))
            }
            id.appendHex(byte)
        }
        return String(decoding: id, as: UTF8.self)
    }

    private func bigEndianBytes(_ value: UInt64) -> [UInt8] {
        stride(from: 56, through: 0, by: -8).map { UInt8(truncatingIfNeeded: value >> $0) }
    }
}

extension String {
    /// The server's `string.uuid` rule: 8-4-4-4-12 hex digits, either case.
    var isUUID: Bool {
        guard utf8.count == 36 else { return false }
        for (index, byte) in utf8.enumerated() {
            let valid: Bool
            switch index {
            case 8, 13, 18, 23:
                valid = byte == UInt8(ascii: "-")
            default:
                valid = (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
            }
            if !valid { return false }
        }
        return true
    }
}
