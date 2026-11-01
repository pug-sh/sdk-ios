import Foundation
import Testing

@testable import Pug

struct TimestampsTests {
    @Test("dates are formatted in UTC with milliseconds")
    func formats() {
        #expect(iso8601(epochMillis: 0) == "1970-01-01T00:00:00.000Z")
        #expect(iso8601(epochMillis: -1) == "1969-12-31T23:59:59.999Z")
        #expect(iso8601(epochMillis: 1_760_000_000_123) == "2025-10-09T08:53:20.123Z")
        #expect(iso8601(epochMillis: 951_782_400_000) == "2000-02-29T00:00:00.000Z")
        #expect(iso8601(epochMillis: -2_203_891_200_000) == "1900-03-01T00:00:00.000Z")
        #expect(iso8601(epochMillis: Limits.timestampMillis.lowerBound) == "0001-01-01T00:00:00.000Z")
        #expect(iso8601(epochMillis: Limits.timestampMillis.upperBound) == "9999-12-31T23:59:59.999Z")
    }

    @Test("formatting agrees with Foundation's on random whole seconds from 1600 to 9999")
    func matchesFoundation() {
        let foundation = ISO8601DateFormatter()
        var random = SeededRandom(seed: 0x150_8601)
        let seconds: ClosedRange<Int64> = -11_676_096_000...Limits.timestampMillis.upperBound / 1_000

        for _ in 0..<500 {
            let second = Int64.random(in: seconds, using: &random)

            let formatted = iso8601(epochMillis: second * 1_000)

            let expected = foundation.string(from: Date(timeIntervalSince1970: Double(second)))
            #expect(formatted == expected.replacingOccurrences(of: "Z", with: ".000Z"), "\(second)")
        }
    }

    @Test("dates convert to the nearest millisecond, and those that do not fit to nil")
    func epochMillis() {
        #expect(Date(timeIntervalSince1970: 1.5).epochMillis == 1_500)
        #expect(Date(timeIntervalSince1970: 1_760_000_000.123).epochMillis == 1_760_000_000_123)
        #expect(Date(timeIntervalSince1970: -0.0004).epochMillis == 0)
        #expect(Date(timeIntervalSince1970: .nan).epochMillis == nil)
        #expect(Date(timeIntervalSince1970: 1e300).epochMillis == nil)
    }
}
