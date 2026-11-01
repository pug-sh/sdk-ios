import Foundation
import Testing

@testable import Pug

struct EventJSONTests {
    private static let eventId = "0192f3a4-1b2c-7d3e-8f40-5a6b7c8d9e0f"
    private static let sessionId = "0192f3a4-0000-7000-8000-000000000002"

    @Test("events round-trip with every value type")
    func roundTrip() throws {
        let event = event(
            custom: [
                "string": .string("quote\" slash\\ newline\n nul\u{0} \u{1F30D}"),
                "empty": .string(""),
                "min": .int(.min),
                "max": .int(.max),
                "zero": .int(0),
                "double": .double(19.99),
                "tiny": .double(.leastNonzeroMagnitude),
                "huge": .double(-1.5e300),
                "whole": .double(2),
                "false": .bool(false),
                "before1970": .timestamp(epochMillis: -1),
                "\u{FC}-key \"quoted\"": .int(1),
            ],
            auto: ["$platform": .string("ios")]
        )

        let decoded = EventJSON.decode(try #require(StoredJSON.parse(EventJSON.encode(event))))

        #expect(decoded == event)
    }

    @Test("the stored shape is the family's domain shape, keys in UTF-16 order")
    func storedShape() {
        let event = event(
            custom: ["n": .int(1), "b": .bool(true), "\u{1F30D}": .double(1.5), "\u{FF5E}": .string("x")],
            auto: ["$at": .timestamp(epochMillis: 5)]
        )

        #expect(
            EventJSON.encode(event)
                == #"{"eventId":"\#(Self.eventId)","kind":"add_to_cart","sessionId":"\#(Self.sessionId)","#
                + #""distinctId":"anon-1","occurTime":1760000000123,"customProperties":{"b":{"boolValue":true},"#
                + #""n":{"intValue":1},"\#u{1F30D}":{"doubleValue":1.5},"\#u{FF5E}":{"stringValue":"x"}},"#
                + #""autoProperties":{"$at":{"timestampValue":5}}}"#
        )
    }

    @Test("missing property maps fail to decode")
    func missingPropertyMaps() throws {
        var json = try object(EventJSON.encode(event()))
        json["autoProperties"] = nil

        #expect(try decode(json) == nil)
    }

    @Test("events the server would reject fail to decode")
    func rejectedEvents() throws {
        let valid = try object(EventJSON.encode(event(custom: ["a": .int(1)])))
        let breaks: [(inout [String: Any]) -> Void] = [
            { $0["eventId"] = nil },
            { $0["eventId"] = "not-a-uuid" },
            { $0["sessionId"] = "" },
            { $0["distinctId"] = "" },
            { $0["kind"] = "has space" },
            { $0["occurTime"] = "soon" },
            { $0["occurTime"] = true },
            { $0["occurTime"] = -1 },
            { $0["occurTime"] = 253_402_300_800_000 },
            custom { $0["a"] = ["stringValue": String(repeating: "\u{E9}", count: 513)] },
            custom { $0["a"] = ["timestampValue": 253_402_300_800_000] },
            custom { $0["$reserved"] = ["intValue": 1] },
            custom { $0["$\u{301}reserved"] = ["intValue": 1] },
            auto { $0["plain"] = ["intValue": 1] },
            custom { $0["a"] = ["floatValue": 1] },
            custom { $0["a"] = ["intValue": 1, "boolValue": true] },
            custom { $0["a"] = ["intValue": "1"] },
            custom { $0["a"] = ["intValue": true] },
            custom { $0["a"] = ["intValue": 1.5] },
            custom { $0["a"] = ["boolValue": 1] },
            custom { $0["a"] = ["doubleValue": false] },
            custom { $0["a"] = [String: Any]() },
            custom { $0["a"] = 1 },
            { $0["customProperties"] = NSNull() },
        ]

        for (index, breakIt) in breaks.enumerated() {
            var json = valid
            breakIt(&json)
            #expect(try decode(json) == nil, "case \(index)")
        }
    }

    private func custom(_ edit: @escaping (inout [String: Any]) -> Void) -> (inout [String: Any]) -> Void {
        editing("customProperties", edit)
    }

    private func auto(_ edit: @escaping (inout [String: Any]) -> Void) -> (inout [String: Any]) -> Void {
        editing("autoProperties", edit)
    }

    private func editing(
        _ key: String,
        _ edit: @escaping (inout [String: Any]) -> Void
    ) -> (inout [String: Any]) -> Void {
        { json in
            var properties = json[key] as? [String: Any] ?? [:]
            edit(&properties)
            json[key] = properties
        }
    }

    private func object(_ text: String) throws -> [String: Any] {
        try #require(StoredJSON.parse(text) as? [String: Any])
    }

    // Through JSON text, so values reach the decoder boxed as JSONSerialization boxes them.
    private func decode(_ json: [String: Any]) throws -> Event? {
        let text = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
        return EventJSON.decode(try #require(StoredJSON.parse(text)))
    }

    private func event(custom: [String: PropertyValue] = [:], auto: [String: PropertyValue] = [:]) -> Event {
        Event(
            eventId: Self.eventId,
            kind: "add_to_cart",
            distinctId: "anon-1",
            sessionId: Self.sessionId,
            occurTimeMillis: 1_760_000_000_123,
            autoProperties: auto,
            customProperties: custom
        )
    }
}
