/// Appends JSON text. A non-finite double is written as null, as `JSON.stringify` writes it.
final class JSONWriter {
  private var out: [UInt8] = []
  private var needsComma = false

  init(capacity: Int = 64) {
    out.reserveCapacity(capacity)
  }

  var text: String {
    String(decoding: out, as: UTF8.self)
  }

  @discardableResult
  func beginObject() -> JSONWriter {
    open(UInt8(ascii: "{"))
  }

  @discardableResult
  func endObject() -> JSONWriter {
    close(UInt8(ascii: "}"))
  }

  @discardableResult
  func beginArray() -> JSONWriter {
    open(UInt8(ascii: "["))
  }

  @discardableResult
  func endArray() -> JSONWriter {
    close(UInt8(ascii: "]"))
  }

  @discardableResult
  func name(_ name: String) -> JSONWriter {
    separate()
    string(name)
    out.append(UInt8(ascii: ":"))
    needsComma = false
    return self
  }

  @discardableResult
  func value(_ value: String) -> JSONWriter {
    separate()
    string(value)
    needsComma = true
    return self
  }

  @discardableResult
  func value(_ value: Int64) -> JSONWriter {
    scalar(String(value))
  }

  @discardableResult
  func value(_ value: Double) -> JSONWriter {
    scalar(value.isFinite ? value.description : "null")
  }

  @discardableResult
  func value(_ value: Bool) -> JSONWriter {
    scalar(value ? "true" : "false")
  }

  @discardableResult
  func nullValue() -> JSONWriter {
    scalar("null")
  }

  private func open(_ bracket: UInt8) -> JSONWriter {
    separate()
    out.append(bracket)
    needsComma = false
    return self
  }

  private func close(_ bracket: UInt8) -> JSONWriter {
    out.append(bracket)
    needsComma = true
    return self
  }

  private func scalar(_ literal: String) -> JSONWriter {
    separate()
    out.append(contentsOf: literal.utf8)
    needsComma = true
    return self
  }

  private func separate() {
    if needsComma {
      out.append(UInt8(ascii: ","))
    }
  }

  // Every byte JSON escapes is ASCII, and UTF-8 never uses ASCII bytes inside a multi-byte
  // sequence, so the scan can work byte by byte.
  private func string(_ value: String) {
    out.append(UInt8(ascii: "\""))
    for byte in value.utf8 {
      switch byte {
      case UInt8(ascii: "\""):
        out.append(contentsOf: #"\""#.utf8)
      case UInt8(ascii: "\\"):
        out.append(contentsOf: #"\\"#.utf8)
      case UInt8(ascii: "\n"):
        out.append(contentsOf: #"\n"#.utf8)
      case UInt8(ascii: "\r"):
        out.append(contentsOf: #"\r"#.utf8)
      case UInt8(ascii: "\t"):
        out.append(contentsOf: #"\t"#.utf8)
      case 0x08:
        out.append(contentsOf: #"\b"#.utf8)
      case 0x0C:
        out.append(contentsOf: #"\f"#.utf8)
      case 0..<0x20:
        out.append(contentsOf: #"\u00"#.utf8)
        out.appendHex(byte)
      default:
        out.append(byte)
      }
    }
    out.append(UInt8(ascii: "\""))
  }
}
