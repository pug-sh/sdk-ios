extension String {
  /// Whether the UTF-8 bytes start with those of `prefix`, as the server's `startsWith` compares them.
  /// `hasPrefix` compares characters, and "$" is no character prefix of "$\u{301}x".
  func hasUTF8Prefix(_ prefix: String) -> Bool {
    utf8.starts(with: prefix.utf8)
  }

  /// Whether the UTF-8 bytes are those of `other`, as the server compares strings. `==` takes canonically equivalent
  /// strings, such as "é" and "e\u{301}", as equal.
  func isUTF8Equal(_ other: String?) -> Bool {
    guard let other else { return false }
    return utf8.elementsEqual(other.utf8)
  }

  /// The longest prefix that fits in `maxBytes` of UTF-8 without splitting a Unicode scalar.
  func truncatedUTF8(maxBytes: Int) -> String {
    let utf8 = self.utf8
    guard let cut = utf8.index(utf8.startIndex, offsetBy: max(maxBytes, 0), limitedBy: utf8.endIndex),
      cut < utf8.endIndex
    else { return self }
    var end = cut
    while end > utf8.startIndex && UTF8.isContinuation(utf8[end]) {
      utf8.formIndex(before: &end)
    }
    return String(unicodeScalars[..<end])
  }
}

extension Dictionary where Key == String {
  /// The entries in UTF-16 code-unit order of their keys, the order protobuf-java and the other Pug
  /// SDKs write maps in. Swift's `<` compares normalized scalars, which orders some keys differently.
  func sortedByUTF16Key() -> [(key: String, value: Value)] {
    sorted { $0.key.utf16.lexicographicallyPrecedes($1.key.utf16) }
  }
}
