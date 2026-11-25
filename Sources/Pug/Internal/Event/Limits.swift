enum Limits {
  // PropertyValue.string_value is capped at 1024 code points. A UTF-8 byte count is never below the
  // code-point count, so capping bytes is stricter than the server, never looser.
  static let maxStringBytes = 1_024

  // The server refuses bodies over 8 MiB with resource_exhausted, which is transient, so an oversized
  // batch would be retried forever. Half the cap leaves room for the request envelope.
  static let maxBatchBytes = 4 * 1_024 * 1_024

  // google.protobuf.Timestamp spans 0001-01-01T00:00:00Z to 9999-12-31T23:59:59.999999999Z.
  static let timestampMillis: ClosedRange<Int64> = -62_135_596_800_000...253_402_300_799_999

  // Event.occur_time must fall in 1970 to 9999.
  static let occurTimeMillis: ClosedRange<Int64> = 0...253_402_300_799_999

  // google.protobuf.Duration spans about ±10,000 years, plus up to 999,999,999 nanos of the same sign.
  static let durationSeconds: ClosedRange<Int64> = -315_576_000_000...315_576_000_000
}
