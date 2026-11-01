import Testing

@testable import Pug

struct Utf8Tests {
  private let samples = [
    "",
    "ascii",
    "h\u{E9}llo w\u{F6}rld",
    "\u{20AC} \u{65E5}\u{672C}",
    "\u{1F30D} emoji",
    "e\u{301} combining",
    "\u{1F44B}\u{1F3FD} \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} \u{1F1E8}\u{1F1ED}",
  ]

  @Test("strings within the limit are returned as they are")
  func withinLimit() {
    let ascii = String(repeating: "a", count: 1_024)
    let twoByte = String(repeating: "\u{E9}", count: 512)

    #expect(ascii.truncatedUTF8(maxBytes: 1_024) == ascii)
    #expect(twoByte.truncatedUTF8(maxBytes: 1_024) == twoByte)
  }

  @Test("truncation stops at the byte limit")
  func stopsAtLimit() {
    let long = String(repeating: "a", count: 1_025)

    #expect(long.truncatedUTF8(maxBytes: 1_024) == String(repeating: "a", count: 1_024))
  }

  @Test("truncation never splits a scalar")
  func neverSplitsAScalar() {
    // é is two bytes: 512 of them fill 1024 bytes exactly, and a 513th would not fit.
    #expect(repeated("\u{E9}", 513).truncatedUTF8(maxBytes: 1_024) == repeated("\u{E9}", 512))
    // € is three bytes: 341 fill 1023, so the 342nd is cut whole.
    #expect(repeated("\u{20AC}", 400).truncatedUTF8(maxBytes: 1_024) == repeated("\u{20AC}", 341))
    // A scalar beyond U+FFFF is four bytes; part of one is never kept.
    #expect(repeated("\u{1F30D}", 300).truncatedUTF8(maxBytes: 1_024) == repeated("\u{1F30D}", 256))
    #expect(
      ("a" + repeated("\u{1F30D}", 300)).truncatedUTF8(maxBytes: 1_024) == "a" + repeated("\u{1F30D}", 255)
    )
  }

  // Android cuts on code points, not on what a reader sees as one character.
  @Test("truncation may split a character between its scalars")
  func cutsBetweenScalars() {
    #expect("e\u{301}".truncatedUTF8(maxBytes: 2).unicodeScalars.elementsEqual("e".unicodeScalars))
    #expect(
      "\u{1F1E8}\u{1F1ED}".truncatedUTF8(maxBytes: 7).unicodeScalars.elementsEqual("\u{1F1E8}".unicodeScalars))
  }

  @Test("a limit of zero or less keeps nothing")
  func zeroLimit() {
    #expect("abc".truncatedUTF8(maxBytes: 0).isEmpty)
    #expect("abc".truncatedUTF8(maxBytes: -1).isEmpty)
    #expect("".truncatedUTF8(maxBytes: 0).isEmpty)
  }

  @Test("truncated strings fit the limit once encoded, and are prefixes of the original")
  func fitsOnceEncoded() {
    let long = String(repeating: samples.joined(separator: "|"), count: 100)

    for limit in [1, 2, 3, 4, 5, 7, 100, 1_024] {
      let truncated = long.truncatedUTF8(maxBytes: limit)
      #expect(truncated.utf8.count <= limit, "limit \(limit)")
      #expect(long.utf8.starts(with: truncated.utf8), "limit \(limit)")
      #expect(long.unicodeScalars.starts(with: truncated.unicodeScalars), "limit \(limit)")
    }
  }

  @Test("UTF-8 prefixes are byte prefixes, even where a combining mark joins the next character")
  func utf8Prefix() {
    #expect("$\u{301}x".hasUTF8Prefix("$"))
    #expect(!"$\u{301}x".hasPrefix("$"))
    #expect("cookieless-abc".hasUTF8Prefix("cookieless-"))
    #expect("abc".hasUTF8Prefix(""))
    #expect(!"ab".hasUTF8Prefix("abc"))
    #expect(!"\u{E9}".hasUTF8Prefix("e"))
  }

  @Test("entries sort by UTF-16 code units, where Swift's own order differs")
  func utf16KeyOrder() {
    let map = ["\u{FF5E}": 1, "\u{1F30D}": 2, "a": 3, "Z": 4, "\u{E9}": 5, "": 6]

    let keys = map.sortedByUTF16Key().map(\.key)

    // U+1F30D is the surrogate pair D83C DF0D in UTF-16, so it sorts before U+FF5E.
    #expect(keys == ["", "Z", "a", "\u{E9}", "\u{1F30D}", "\u{FF5E}"])
    #expect("\u{FF5E}" < "\u{1F30D}")
  }

  private func repeated(_ string: String, _ count: Int) -> String {
    String(repeating: string, count: count)
  }
}
