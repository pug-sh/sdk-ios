import Testing

@testable import Pug

struct EventSchemaTests {
    @Test("a duration is written in seconds with the fraction it needs")
    func formatsDurations() {
        let millis: [Int64] = [0, 1, 10, 1_500, 1_234, 61_000, -1, -1_500, .min]

        #expect(
            millis.map { durationText(milliseconds: $0) } == [
                "0s", "0.001s", "0.01s", "1.5s", "1.234s", "61s", "-0.001s", "-1.5s", "-9223372036854775.808s",
            ]
        )
    }

    @Test("a duration is rounded to the millisecond, and one that does not fit is nil")
    func roundsDurations() {
        #expect(durationMilliseconds(1.5) == 1_500)
        #expect(durationMilliseconds(1.2344) == 1_234)
        #expect(durationMilliseconds(1.2346) == 1_235)
        #expect(durationMilliseconds(-0.0) == 0)
        #expect(durationMilliseconds(.nan) == nil)
        #expect(durationMilliseconds(.infinity) == nil)
        #expect(durationMilliseconds(1e300) == nil)
    }
}
