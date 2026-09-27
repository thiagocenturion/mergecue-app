import Foundation
import MergeCueCore
import Testing

@Suite("JSONValue")
struct JSONValueTests {
    @Test func parsesEveryKind() throws {
        let value = try JSONValue.parse(#"{"a":null,"b":true,"c":1.5,"d":"x","e":[1,"two",false],"f":{"g":42}}"#)
        #expect(value["a"] == .null)
        #expect(value["a"]?.isNull == true)
        #expect(value["b"]?.boolValue == true)
        #expect(value["c"]?.doubleValue == 1.5)
        #expect(value["c"]?.intValue == nil)
        #expect(value["d"]?.stringValue == "x")
        #expect(value["e"]?[1]?.stringValue == "two")
        #expect(value["e"]?[2]?.boolValue == false)
        #expect(value["e"]?[3] == nil)
        #expect(value["f"]?["g"]?.intValue == 42)
        #expect(value["missing"] == nil)
        #expect(value[0] == nil)
        #expect(value.objectValue?.count == 6)
    }

    @Test func numbersAreNotBooleans() throws {
        #expect(try JSONValue.parse("1") == .number(1))
        #expect(try JSONValue.parse("0") == .number(0))
        #expect(try JSONValue.parse("true") == .bool(true))
    }

    @Test func literalsAndSerialization() {
        let value: JSONValue = ["name": "mergecue", "count": 3, "ratio": 0.5, "on": true, "none": nil, "tags": ["a", "b"]]
        #expect(value.jsonString() == #"{"count":3,"name":"mergecue","none":null,"on":true,"ratio":0.5,"tags":["a","b"]}"#)
        #expect(value["count"]?.intValue == 3)
    }

    @Test func roundTripsThroughCodable() throws {
        let value: JSONValue = ["nested": ["deep": [1, 2, ["x": "y"]]], "empty": [:], "list": []]
        #expect(try Fixture.roundTrip(value) == value)
        #expect(try JSONValue.parse(value.jsonString(pretty: true)) == value)
    }

    private struct Params: Codable, Equatable {
        var taskID: String
        var at: Date
        var limit: Int?

        enum CodingKeys: String, CodingKey {
            case taskID = "task_id"
            case at, limit
        }
    }

    @Test func convertsToAndFromTypedValues() throws {
        let params = Params(taskID: "mc_abc123", at: Fixture.date, limit: nil)
        let json = try JSONValue(encoding: params)
        #expect(json["task_id"]?.stringValue == "mc_abc123")
        #expect(json["at"]?.stringValue == "2026-01-01T00:00:00Z")
        #expect(try json.decode(Params.self) == params)
        #expect(throws: DecodingError.self) { try JSONValue.string("nope").decode(Params.self) }
    }

    @Test func integerAccessorBounds() {
        #expect(JSONValue.number(9_007_199_254_740_992).intValue == 9_007_199_254_740_992)
        #expect(JSONValue.number(1e300).intValue == nil)
        #expect(JSONValue.number(-3).intValue == -3)
        #expect(JSONValue.string("3").intValue == nil)
    }
}
