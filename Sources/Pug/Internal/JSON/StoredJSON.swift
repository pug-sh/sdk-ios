import Foundation

/// Reads JSON the SDK stored, through `JSONSerialization`. That boxes numbers and booleans alike in `NSNumber`,
/// which Swift casts across (`true as? Int64` is 1), so scalars are told apart by `HostValue` first.
enum StoredJSON {
    /// The array or object in `text`, or nil when it holds neither.
    static func parse(_ text: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    /// A whole number that fits in an `Int64`.
    static func int64(_ value: Any?) -> Int64? {
        // Linux reads -2^63 as an NSDecimalNumber, whose digits a double could round.
        if let decimal = value as? NSDecimalNumber, let integer = Int64(decimal.description) {
            return integer
        }
        switch HostValue(value) {
        case .integer(let integer):
            return integer
        case .decimal(let decimal):
            return Int64(exactly: decimal)
        default:
            return nil
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch HostValue(value) {
        case .integer(let integer):
            return Double(integer)
        case .decimal(let decimal):
            return decimal
        case .digits(let digits):
            return Double(digits)
        default:
            return nil
        }
    }

    static func bool(_ value: Any?) -> Bool? {
        guard case .bool(let bool) = HostValue(value) else { return nil }
        return bool
    }
}
