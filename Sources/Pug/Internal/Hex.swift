private let hexDigits = Array("0123456789abcdef".utf8)

extension [UInt8] {
  mutating func appendHex(_ byte: UInt8) {
    append(hexDigits[Int(byte >> 4)])
    append(hexDigits[Int(byte & 0x0F)])
  }
}
