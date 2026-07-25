import XCTest
@testable import EslSpeakingCoach

final class ClaudeSSEParserTests: XCTestCase {
    func testTextDelta() throws {
        let line = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#
        XCTAssertEqual(try ClaudeSSE.parse(line: line), .textDelta("Hello"))
    }

    func testThinkingDeltaIsIgnored() throws {
        let line = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#
        XCTAssertNil(try ClaudeSSE.parse(line: line))
    }

    func testMessageDeltaCarriesStopReason() throws {
        let line = #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":12}}"#
        XCTAssertEqual(try ClaudeSSE.parse(line: line), .messageStopped(stopReason: "end_turn"))
    }

    func testNonDataLinesAreIgnored() throws {
        XCTAssertNil(try ClaudeSSE.parse(line: "event: content_block_delta"))
        XCTAssertNil(try ClaudeSSE.parse(line: ""))
        XCTAssertNil(try ClaudeSSE.parse(line: #"data: {"type":"ping"}"#))
    }

    func testErrorEventThrows() {
        let line = #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        XCTAssertThrowsError(try ClaudeSSE.parse(line: line)) { error in
            guard case ClaudeClientError.apiError(let message) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(message, "Overloaded")
        }
    }
}

final class ClaudeRequestBodyTests: XCTestCase {
    func testRequestBodyFollowsProjectRules() throws {
        let messages = [
            ConversationMessage(role: .user, text: "Hi!"),
            ConversationMessage(role: .assistant, text: "Hello! How was your day?"),
            ConversationMessage(role: .user, text: "Pretty good."),
        ]
        let data = try ClaudeMessagesClient.makeRequestBody(
            parameters: .init(), system: "You are a coach.", messages: messages)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["model"] as? String, "claude-opus-5")
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["max_tokens"] as? Int, 1024)

        // claude-opus-5 では 400 になるため送ってはいけないパラメータ（CLAUDE.md の規約）
        XCTAssertNil(json["temperature"])
        XCTAssertNil(json["top_p"])
        XCTAssertNil(json["top_k"])

        let outputConfig = try XCTUnwrap(json["output_config"] as? [String: Any])
        XCTAssertEqual(outputConfig["effort"] as? String, "low")

        let system = try XCTUnwrap(json["system"] as? [[String: Any]])
        XCTAssertEqual(system.count, 1)
        XCTAssertEqual(system[0]["type"] as? String, "text")
        let cacheControl = try XCTUnwrap(system[0]["cache_control"] as? [String: Any])
        XCTAssertEqual(cacheControl["type"] as? String, "ephemeral")

        let encodedMessages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(encodedMessages.map { $0["role"] as? String }, ["user", "assistant", "user"])
        XCTAssertEqual(encodedMessages[0]["content"] as? String, "Hi!")
    }
}
