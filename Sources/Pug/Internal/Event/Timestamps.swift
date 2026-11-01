import Foundation

extension Date {
    /// Milliseconds since 1970, rounded to the nearest so that a date made from whole milliseconds
    /// keeps them; nil when they do not fit in an `Int64`.
    var epochMillis: Int64? {
        Int64(exactly: (timeIntervalSince1970 * 1_000).rounded())
    }
}

/// ISO 8601 in UTC with milliseconds, as JavaScript's `Date.toJSON` writes it, in the proleptic
/// Gregorian calendar. Meant for the years 1 to 9999, which take four digits.
func iso8601(epochMillis: Int64) -> String {
    let (days, millisOfDay) = floorDivision(epochMillis, 86_400_000)
    let (year, month, day) = civilDate(daysSince1970: days)
    let hour = millisOfDay / 3_600_000
    let minute = millisOfDay / 60_000 % 60
    let second = millisOfDay / 1_000 % 60
    let millis = millisOfDay % 1_000
    return "\(padded(year, 4))-\(padded(month, 2))-\(padded(day, 2))"
        + "T\(padded(hour, 2)):\(padded(minute, 2)):\(padded(second, 2)).\(padded(millis, 3))Z"
}

private func floorDivision(_ value: Int64, _ divisor: Int64) -> (quotient: Int64, remainder: Int64) {
    let (quotient, remainder) = value.quotientAndRemainder(dividingBy: divisor)
    return remainder < 0 ? (quotient - 1, remainder + divisor) : (quotient, remainder)
}

// Howard Hinnant's civil_from_days: eras of 400 years, each starting on March 1 so that the leap day
// ends the year.
private func civilDate(daysSince1970 days: Int64) -> (year: Int64, month: Int64, day: Int64) {
    let shifted = days + 719_468
    let era = floorDivision(shifted, 146_097).quotient
    let dayOfEra = shifted - era * 146_097
    let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
    let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
    let shiftedMonth = (5 * dayOfYear + 2) / 153
    let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
    let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
    return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
}

private func padded(_ value: Int64, _ width: Int) -> String {
    let digits = String(value)
    return String(repeating: "0", count: max(width - digits.count, 0)) + digits
}
