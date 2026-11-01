import Testing

@testable import Pug

struct StoredJSONTests {
  @Test("integers are whole numbers that fit in an Int64, never booleans or text")
  func integers() throws {
    let values = try #require(
      StoredJSON.parse(
        #"[1, -1, 1.0, 1.5, 9223372036854775807, -9223372036854775808, 9223372036854775808, 1e300, "#
          + #"true, false, "1", null, {}]"#
      ) as? [Any]
    )

    #expect(
      values.map(StoredJSON.int64) == [
        1, -1, 1, nil, .max, .min, nil, nil, nil, nil, nil, nil, nil,
      ]
    )
  }

  @Test("doubles are any number, never booleans or text")
  func doubles() throws {
    let values = try #require(StoredJSON.parse(#"[2.0, 19.99, 5e-324, -1.5e300, 3, true, "1", null]"#) as? [Any])

    #expect(
      values.map(StoredJSON.double) == [
        2.0, 19.99, .leastNonzeroMagnitude, -1.5e300, 3, nil, nil, nil,
      ]
    )
  }

  @Test("booleans are true and false, never the numbers 0 and 1")
  func booleans() throws {
    let values = try #require(StoredJSON.parse(#"[true, false, 1, 0, "true", null]"#) as? [Any])

    #expect(values.map(StoredJSON.bool) == [true, false, nil, nil, nil, nil])
  }

  @Test("only arrays and objects parse")
  func topLevel() {
    #expect(StoredJSON.parse("[]") is [Any])
    #expect(StoredJSON.parse("{}") is [String: Any])
    for text in ["", "not json", #""string""#, "1", "{"] {
      #expect(StoredJSON.parse(text) == nil, "\(text)")
    }
  }
}
