import Foundation
import Testing

@testable import Pug

struct JSONWriterTests {
    @Test("writes nested objects and arrays with separators")
    func nesting() {
        let json = JSONWriter()
            .beginObject()
            .name("a")
            .value(Int64(1))
            .name("b")
            .beginArray()
            .value(true)
            .nullValue()
            .beginObject()
            .endObject()
            .beginArray()
            .endArray()
            .value(1.5)
            .endArray()
            .name("c")
            .value("x")
            .endObject()
            .text

        #expect(json == #"{"a":1,"b":[true,null,{},[],1.5],"c":"x"}"#)
    }

    @Test("escapes what JSON requires and keeps the rest")
    func escapes() throws {
        let tricky =
            "quote\" backslash\\ newline\n tab\t cr\r bs\u{8} ff\u{C} nul\u{0} unit\u{1F} \u{E9} \u{1F30D} \u{2028} /"

        let json = JSONWriter().beginObject().name(tricky).value(tricky).endObject().text

        let escaped =
            #""quote\" backslash\\ newline\n tab\t cr\r bs\b ff\f nul\u0000 unit\u001f \#u{E9} \#u{1F30D} \#u{2028} /""#
        #expect(json == "{\(escaped):\(escaped)}")
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String])
        #expect(parsed == [tricky: tricky])
    }

    @Test("numbers keep their exact value")
    func exactNumbers() throws {
        let integers: [Int64] = [.min, .max, 0, -1]
        let doubles = [
            Double.leastNonzeroMagnitude, .greatestFiniteMagnitude, 0.1, -2.5e-300, 1e21, -0.0, 3,
            2.2250738585072014e-308,
        ]
        let writer = JSONWriter().beginArray()
        for integer in integers {
            writer.value(integer)
        }
        for double in doubles {
            writer.value(double)
        }

        let json = writer.endArray().text

        #expect(try JSONSerialization.jsonObject(with: Data(json.utf8)) is [Any])
        let tokens = json.dropFirst().dropLast().split(separator: ",").map(String.init)
        #expect(tokens.prefix(integers.count).map { Int64($0) } == integers)
        for (token, double) in zip(tokens.dropFirst(integers.count), doubles) {
            let parsed = try #require(Double(token))
            #expect(parsed.bitPattern == double.bitPattern, "\(token)")
        }
    }

    @Test("non-finite doubles become null, as JSON.stringify writes them")
    func nonFinite() {
        let json = JSONWriter().beginArray().value(Double.nan).value(Double.infinity).value(-Double.infinity).endArray()

        #expect(json.text == "[null,null,null]")
    }
}
