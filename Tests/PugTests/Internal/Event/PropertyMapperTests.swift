import Foundation
import Testing

@testable import Pug

struct PropertyMapperTests {
    private enum Plan: String {
        case pro = "PRO"
    }

    private enum Tier {
        case gold
    }

    private enum Level: Int {
        case high = 3
    }

    private struct Point {
        let x: Int
        let y: Int
    }

    private let logger = RecordingLogger()
    private var mapper: PropertyMapper {
        PropertyMapper(logger: logger.safe())
    }

    @Test("a whole number for a double property of a well-known event is sent as a double")
    func doubleCoercion() {
        #expect(
            mapper.mapCustom(kind: "add_to_cart", ["price": 10, "quantity": 2, "productId": "p1"])
                == ["price": .double(10), "quantity": .int(2), "productId": .string("p1")]
        )
        #expect(mapper.mapCustom(kind: "checkout", ["price": 10]) == ["price": .int(10)])
    }

    @Test("Swift scalars map onto their PropertyValue type")
    func scalars() {
        let text = "a substring"
        let mapped = mapper.mapCustom(
            kind: "kind",
            [
                "string": "s",
                "substring": text.dropFirst(2),
                "character": Character("c"),
                "stringEnum": Plan.pro,
                "name": Notification.Name("didFinish"),
                "true": true,
                "int": 3,
                "int8": Int8(-1),
                "int16": Int16(2),
                "int32": Int32.min,
                "int64": Int64.max,
                "uint": UInt(4),
                "uint8": UInt8.max,
                "uint32": UInt32.max,
                "uint64": UInt64(Int64.max),
                "double": 2.5,
                "float": Float(0.1),
                "cgFloat": CGFloat(1.5),
                "decimal": Decimal(string: "1.25") as Any,
            ]
        )

        let expected: [String: PropertyValue] = [
            "string": .string("s"),
            "substring": .string("substring"),
            "character": .string("c"),
            "stringEnum": .string("PRO"),
            "name": .string("didFinish"),
            "true": .bool(true),
            "int": .int(3),
            "int8": .int(-1),
            "int16": .int(2),
            "int32": .int(Int64(Int32.min)),
            "int64": .int(.max),
            "uint": .int(4),
            "uint8": .int(255),
            "uint32": .int(4_294_967_295),
            "uint64": .int(.max),
            "double": .double(2.5),
            "float": .double(0.1),
            "cgFloat": .double(1.5),
            "decimal": .double(1.25),
        ]
        #expect(mapped == expected)
        #expect(logger.entries.isEmpty)
    }

    @Test("NSNumbers map by their type, so only a CFBoolean is a bool")
    func numbers() {
        let mapped = mapper.mapCustom(
            kind: "kind",
            [
                "true": NSNumber(value: true),
                "false": NSNumber(value: false),
                "one": NSNumber(value: 1),
                "zero": NSNumber(value: 0),
                "int8": NSNumber(value: Int8(1)),
                "uint8": NSNumber(value: UInt8.max),
                "wide": NSNumber(value: UInt64.max),
                "float": NSNumber(value: Float(0.1)),
                "double": NSNumber(value: 2.5),
                "decimal": NSDecimalNumber(string: "1.25"),
            ]
        )

        let expected: [String: PropertyValue] = [
            "true": .bool(true),
            "false": .bool(false),
            "one": .int(1),
            "zero": .int(0),
            "int8": .int(1),
            "uint8": .int(255),
            "wide": .string("18446744073709551615"),
            "float": .double(0.1),
            "double": .double(2.5),
            "decimal": .double(1.25),
        ]
        #expect(mapped == expected)
    }

    @Test("values from JSONSerialization keep their JSON types")
    func jsonSerialization() throws {
        let json = #"{"t":true,"f":false,"one":1,"zero":0,"half":0.5,"text":"x","null":null,"list":[1,true]}"#
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])

        let expected: [String: PropertyValue] = [
            "t": .bool(true),
            "f": .bool(false),
            "one": .int(1),
            "zero": .int(0),
            "half": .double(0.5),
            "text": .string("x"),
            "list": .string("[1,true]"),
        ]
        #expect(mapper.mapCustom(kind: "kind", parsed) == expected)
        #expect(logger.entries.isEmpty)
    }

    @Test("integers too wide for int64 keep their digits as a string")
    func wideIntegers() {
        let mapped = mapper.mapCustom(kind: "kind", ["fits": Int64.min, "wide": UInt64.max])

        #expect(mapped == ["fits": .int(.min), "wide": .string("18446744073709551615")])
    }

    @Test("dates map onto timestamps, to the nearest millisecond")
    func dates() {
        let mapped = mapper.mapCustom(
            kind: "kind",
            [
                "date": Date(timeIntervalSince1970: 1_760_000_000.123),
                "before1970": NSDate(timeIntervalSince1970: -1),
                "distantFuture": Date.distantFuture,
            ]
        )

        let expected: [String: PropertyValue] = [
            "date": .timestamp(epochMillis: 1_760_000_000_123),
            "before1970": .timestamp(epochMillis: -1_000),
            "distantFuture": .timestamp(epochMillis: 64_092_211_200_000),
        ]
        #expect(mapped == expected)
    }

    @Test("times outside the years 1 to 9999 are dropped")
    func timesOutOfRange() {
        let first = Limits.timestampMillis.lowerBound
        let last = Limits.timestampMillis.upperBound

        let mapped = mapper.mapCustom(
            kind: "kind",
            [
                "first": date(millis: first),
                "last": date(millis: last),
                "before": date(millis: first - 1),
                "after": date(millis: last + 1),
                "distantPast": Date.distantPast,
                "nan": Date(timeIntervalSince1970: .nan),
            ]
        )

        #expect(mapped == ["first": .timestamp(epochMillis: first), "last": .timestamp(epochMillis: last)])
        #expect(logger.warnings.count == 4)
        #expect(logger.warnings.allSatisfy { $0.hasSuffix("the time is outside the years 1 to 9999") })
    }

    @Test("non-finite numbers are dropped with a warning")
    func nonFinite() {
        let mapped = mapper.mapCustom(
            kind: "kind",
            ["nan": Double.nan, "inf": Float.infinity, "negativeInf": -Double.infinity, "ok": 1.0]
        )

        #expect(mapped == ["ok": .double(1)])
        #expect(
            logger.warnings == [
                "Property \"inf\" on event \"kind\" was dropped: inf is not a finite number",
                "Property \"nan\" on event \"kind\" was dropped: nan is not a finite number",
                "Property \"negativeInf\" on event \"kind\" was dropped: -inf is not a finite number",
            ]
        )
    }

    @Test("nil, Optional.none and NSNull are dropped silently")
    func absentValues() {
        let none: Int? = nil
        let nested: Int?? = .some(nil)
        let some: Int? = 5

        let mapped = mapper.mapCustom(
            kind: "kind",
            [
                "none": none as Any, "nested": nested as Any, "null": NSNull(), "$reserved": none as Any,
                "some": some as Any,
            ]
        )

        #expect(mapped == ["some": .int(5)])
        #expect(logger.entries.isEmpty)
    }

    @Test("values of other types are sent as their text")
    func otherTypes() throws {
        let id = try #require(UUID(uuidString: "0190A5B4-7C2E-7A3B-8F00-0123456789AB"))
        let url = try #require(URL(string: "https://pug.sh/docs?q=1"))
        let long = String(repeating: "x", count: 2_000)

        let mapped = mapper.mapCustom(
            kind: "kind",
            [
                "id": id,
                "url": url,
                "tuple": (1, 2),
                "struct": Point(x: 1, y: 2),
                "enum": Tier.gold,
                "intEnum": Level.high,
                "nested": [id],
                "long": Substring(long),
            ]
        )

        let expected: [String: PropertyValue] = [
            "id": .string("0190A5B4-7C2E-7A3B-8F00-0123456789AB"),
            "url": .string("https://pug.sh/docs?q=1"),
            "tuple": .string("(1, 2)"),
            "struct": .string("Point(x: 1, y: 2)"),
            "enum": .string("gold"),
            "intEnum": .string("high"),
            "nested": .string(#"["0190A5B4-7C2E-7A3B-8F00-0123456789AB"]"#),
            "long": .string(String(repeating: "x", count: 1_024)),
        ]
        #expect(mapped == expected)
        #expect(logger.warnings == ["Property \"long\" on event \"kind\" was truncated to 1024 bytes"])
    }

    @Test("custom keys may not start with a dollar sign")
    func reservedCustomKeys() {
        let mapped = mapper.mapCustom(kind: "kind", ["$os": "spoofed", "os": "fine"])

        #expect(mapped == ["os": .string("fine")])
        #expect(
            logger.warnings == [#"Property "$os" on event "kind" was dropped: keys starting with '$' are reserved"#])
    }

    @Test("auto-property keys must start with a dollar sign")
    func autoKeys() {
        let mapped = mapper.mapAuto(kind: "kind", ["$os": "iOS", "os": "bug"])

        #expect(mapped == ["$os": .string("iOS")])
        #expect(logger.warnings == [#"Auto-property "os" was dropped: auto-property keys start with '$'"#])
    }

    @Test("long strings are truncated to 1024 UTF-8 bytes")
    func truncation() {
        let mapped = mapper.mapCustom(
            kind: "kind",
            [
                "ascii": String(repeating: "a", count: 2_000),
                "emoji": String(repeating: "\u{1F30D}", count: 300),
                "exact": String(repeating: "b", count: 1_024),
            ]
        )

        #expect(mapped["ascii"] == .string(String(repeating: "a", count: 1_024)))
        #expect(mapped["emoji"] == .string(String(repeating: "\u{1F30D}", count: 256)))
        #expect(mapped["exact"] == .string(String(repeating: "b", count: 1_024)))
        #expect(
            logger.warnings == [
                "Property \"ascii\" on event \"kind\" was truncated to 1024 bytes",
                "Property \"emoji\" on event \"kind\" was truncated to 1024 bytes",
            ]
        )
    }

    @Test("arrays, dictionaries and sets become JSON strings, keys and set elements sorted")
    func collections() {
        let none: Int? = nil
        let mapped = mapper.mapCustom(
            kind: "kind",
            [
                "dictionary": ["b": [true, none as Any, 2.5], "a": 1, 3: "int key"] as [AnyHashable: Any],
                "array": ["x", Plan.pro, Character("c"), 10.0, Float(1.5)] as [Any],
                "set": Set([3, 1, 2]),
                "optionals": ["a", nil] as [String?],
                "bytes": [UInt8.max],
                "nonFinite": [Double.nan, -Double.infinity],
                "wide": [Int64.max, 9_007_199_254_740_991, UInt64.max] as [Any],
                "dates": [Date(timeIntervalSince1970: 1_760_000_000.123)],
                "foundation": NSArray(array: [NSNumber(value: true), NSNumber(value: 1), NSDictionary()]),
                "empty": [String: Int](),
            ]
        )

        let expected: [String: PropertyValue] = [
            "dictionary": .string(#"{"3":"int key","a":1,"b":[true,null,2.5]}"#),
            "array": .string(#"["x","PRO","c",10,1.5]"#),
            "set": .string("[1,2,3]"),
            "optionals": .string(#"["a",null]"#),
            "bytes": .string("[255]"),
            "nonFinite": .string("[null,null]"),
            "wide": .string(#"["9223372036854775807",9007199254740991,"18446744073709551615"]"#),
            "dates": .string(#"["2025-10-09T08:53:20.123Z"]"#),
            "foundation": .string("[true,1,{}]"),
            "empty": .string("{}"),
        ]
        #expect(mapped == expected)
        #expect(logger.entries.isEmpty)
    }

    @Test("JSON strings are truncated like any string")
    func jsonTruncation() throws {
        let mapped = mapper.mapCustom(kind: "kind", ["list": Array(repeating: "item", count: 1_000)])

        guard case .string(let json) = try #require(mapped["list"]) else {
            Issue.record("list is not a string")
            return
        }
        #expect(json.utf8.count == 1_024)
        #expect(json.hasPrefix(#"["item","item""#))
        #expect(logger.warnings == ["Property \"list\" on event \"kind\" was truncated to 1024 bytes"])
    }

    @Test("deeply nested structures are dropped")
    func deepStructures() {
        var deep: Any = "bottom"
        for _ in 0..<40 {
            deep = [deep]
        }

        let mapped = mapper.mapCustom(kind: "kind", ["deep": deep, "kept": 1])

        #expect(mapped == ["kept": .int(1)])
        #expect(
            logger.warnings == [
                "Property \"deep\" on event \"kind\" was dropped: it is nested more than 32 levels deep"
            ])
    }

    // Linux's Foundation bridges a self-containing NSArray to Swift eagerly, which overflows the stack
    // before the SDK sees it; Apple's bridges lazily.
    #if canImport(Darwin)
    @Test("a self-containing array is dropped")
    func cyclicArray() {
        let cyclic = NSMutableArray()
        cyclic.add(cyclic)

        #expect(mapper.mapCustom(kind: "kind", ["cyclic": cyclic]).isEmpty)
        #expect(
            logger.warnings == [
                "Property \"cyclic\" on event \"kind\" was dropped: it is nested more than 32 levels deep"
            ])
        cyclic.removeAllObjects()
    }
    #endif

    @Test("structures holding more than 10000 values are dropped")
    func largeStructures() {
        let mapped = mapper.mapCustom(
            kind: "kind",
            [
                "large": Array(0..<10_000),
                "nils": Array(repeating: nil, count: 10_000) as [Int?],
                "small": Array(0..<9_999),
            ]
        )

        #expect(Set(mapped.keys) == ["small"])
        #expect(
            logger.warnings.filter { $0.contains("dropped") } == [
                "Property \"large\" on event \"kind\" was dropped: it holds more than 10000 values",
                "Property \"nils\" on event \"kind\" was dropped: it holds more than 10000 values",
            ]
        )
    }

    @Test("two dictionary keys with one text resolve the same way every time")
    func collidingKeys() {
        for _ in 0..<20 {
            let mapped = mapper.mapCustom(
                kind: "kind", ["dictionary": [1: "int", "1": "string"] as [AnyHashable: Any]])

            #expect(mapped == ["dictionary": .string(#"{"1":"string"}"#)])
        }
    }

    @Test("a typed call names its values from the schema and warns of required properties it does not send")
    func typedValues() {
        let event = EventSchema(
            kind: "checkout",
            method: "checkout",
            fields: [
                FieldSchema("orderId", .string, required: true),
                FieldSchema("total", .double, required: true),
                FieldSchema("wait", .duration),
                FieldSchema("note", .string),
            ]
        )

        let mapped = mapper.mapTyped(event, values: ["o1", Double.nan, 0.25, nil], extras: ["note": "extra"])

        #expect(mapped == ["orderId": .string("o1"), "wait": .string("0.25s"), "note": .string("extra")])
        #expect(
            logger.warnings == [
                "Property \"total\" on event \"checkout\" was dropped: nan is not a finite number",
                "Pug.track.checkout() was tracked without its required total",
            ]
        )
    }

    private func date(millis: Int64) -> Date {
        Date(timeIntervalSince1970: Double(millis) / 1_000)
    }
}
