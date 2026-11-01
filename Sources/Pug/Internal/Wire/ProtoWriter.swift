enum WireType: UInt32 {
  case varint = 0
  case i64 = 1
  case len = 2
  case i32 = 5
}

func varintSize(_ value: UInt64) -> Int {
  let bits = UInt64.bitWidth - value.leadingZeroBitCount
  return bits == 0 ? 1 : (bits + 6) / 7
}

struct ProtoWriter {
  private(set) var bytes: [UInt8] = []

  init(capacity: Int = 64) {
    bytes.reserveCapacity(capacity)
  }

  mutating func writeString(field: UInt32, _ value: String) {
    writeTag(field, .len)
    writeVarint(UInt64(value.utf8.count))
    bytes.append(contentsOf: value.utf8)
  }

  mutating func writeInt64(field: UInt32, _ value: Int64) {
    writeTag(field, .varint)
    writeVarint(UInt64(bitPattern: value))
  }

  /// Negative values sign-extend to a 10-byte varint, as protobuf requires for int32 and enums.
  mutating func writeInt32(field: UInt32, _ value: Int32) {
    writeTag(field, .varint)
    writeVarint(UInt64(bitPattern: Int64(value)))
  }

  mutating func writeBool(field: UInt32, _ value: Bool) {
    writeTag(field, .varint)
    writeVarint(value ? 1 : 0)
  }

  mutating func writeDouble(field: UInt32, _ value: Double) {
    writeTag(field, .i64)
    for shift in stride(from: 0, to: 64, by: 8) {
      bytes.append(UInt8(truncatingIfNeeded: value.bitPattern >> shift))
    }
  }

  mutating func writeMessage(field: UInt32, _ message: ProtoWriter) {
    writeTag(field, .len)
    writeVarint(UInt64(message.bytes.count))
    bytes.append(contentsOf: message.bytes)
  }

  private mutating func writeTag(_ field: UInt32, _ wireType: WireType) {
    writeVarint(UInt64(field) << 3 | UInt64(wireType.rawValue))
  }

  private mutating func writeVarint(_ value: UInt64) {
    var remaining = value
    while remaining > 0x7F {
      bytes.append(UInt8(truncatingIfNeeded: remaining) | 0x80)
      remaining >>= 7
    }
    bytes.append(UInt8(truncatingIfNeeded: remaining))
  }
}
