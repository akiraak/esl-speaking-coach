import XCTest
@testable import EslSpeakingCoach

final class TopicSuggestionClientTests: XCTestCase {
    func testRequestBodyFollowsProjectRules() throws {
        let data = try TopicSuggestionClient.makeRequestBody(
            recentTitles: ["Planning a trip", "Food you can't quit"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["model"] as? String, "claude-sonnet-5")
        XCTAssertNil(json["stream"])
        // claude-sonnet-5 では 400 になるため送ってはいけないパラメータ（CLAUDE.md の規約）
        XCTAssertNil(json["temperature"])
        XCTAssertNil(json["top_p"])
        XCTAssertNil(json["top_k"])

        let outputConfig = try XCTUnwrap(json["output_config"] as? [String: Any])
        XCTAssertEqual(outputConfig["effort"] as? String, "low")
        let format = try XCTUnwrap(outputConfig["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(schema["required"] as? [String], ["topics"])

        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(
            messages[0]["content"] as? String,
            "Recent topics: Planning a trip, Food you can't quit")
    }

    func testRequestBodyWithNoRecentTopics() throws {
        let data = try TopicSuggestionClient.makeRequestBody(recentTitles: [])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages[0]["content"] as? String, "Recent topics: (none)")
    }

    func testParseResponseExtractsTopics() throws {
        let inner = #"{"topics":[{"title":"Morning routines","hook":"What starts your day right?"},{"title":"A trip you remember","hook":"Where did you go?"},{"title":"Comfort food","hook":"What do you eat when tired?"}]}"#
        let response = try JSONSerialization.data(withJSONObject: [
            "content": [["type": "text", "text": inner]],
            "stop_reason": "end_turn",
        ])
        let topics = try TopicSuggestionClient.parseResponse(response)
        XCTAssertEqual(topics.count, 3)
        XCTAssertEqual(topics[0].title, "Morning routines")
        XCTAssertEqual(topics[0].hook, "What starts your day right?")
    }

    /// stop_reason=refusal のとき content を読まずに投げる（CLAUDE.md の規約）。
    func testParseResponseThrowsOnRefusal() throws {
        let response = try JSONSerialization.data(withJSONObject: [
            "content": [],
            "stop_reason": "refusal",
        ])
        XCTAssertThrowsError(try TopicSuggestionClient.parseResponse(response)) { error in
            guard case TopicSuggestionError.refusal = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testParseResponseThrowsOnMalformedContent() throws {
        let response = try JSONSerialization.data(withJSONObject: [
            "content": [["type": "text", "text": "not json"]],
            "stop_reason": "end_turn",
        ])
        XCTAssertThrowsError(try TopicSuggestionClient.parseResponse(response))
    }
}
