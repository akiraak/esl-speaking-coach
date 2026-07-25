import XCTest
@testable import EslSpeakingCoach

final class ClaudeSSEParserTests: XCTestCase {
    func testTextDelta() throws {
        let line = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#
        XCTAssertEqual(try ClaudeSSE.parse(line: line), [.textDelta("Hello")])
    }

    func testThinkingDeltaIsIgnored() throws {
        let line = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#
        XCTAssertEqual(try ClaudeSSE.parse(line: line), [])
    }

    /// message_delta は usage → stop の順で 2 イベントになる（usage を先に積んでから stop を処理する）。
    func testMessageDeltaCarriesUsageAndStopReason() throws {
        let line = #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":12}}"#
        XCTAssertEqual(try ClaudeSSE.parse(line: line), [
            .usageUpdated(ClaudeTokenUsage(outputTokens: 12)),
            .messageStopped(stopReason: "end_turn"),
        ])
    }

    /// 入力側の usage（input_tokens / cache_*）は message_start に載る。
    func testMessageStartCarriesInputUsage() throws {
        let line = #"data: {"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":1500,"output_tokens":1,"cache_read_input_tokens":2000,"cache_creation_input_tokens":0}}}"#
        XCTAssertEqual(try ClaudeSSE.parse(line: line), [
            .usageUpdated(ClaudeTokenUsage(
                inputTokens: 1500, outputTokens: 1,
                cacheReadInputTokens: 2000, cacheCreationInputTokens: 0)),
        ])
    }

    func testTokenUsageMergeKeepsExistingWhenNil() {
        var usage = ClaudeTokenUsage(inputTokens: 100, cacheReadInputTokens: 2000)
        usage.merge(ClaudeTokenUsage(outputTokens: 50))
        XCTAssertEqual(usage.inputTokens, 100)
        XCTAssertEqual(usage.outputTokens, 50)
        XCTAssertEqual(usage.cacheReadInputTokens, 2000)
    }

    func testNonDataLinesAreIgnored() throws {
        XCTAssertEqual(try ClaudeSSE.parse(line: "event: content_block_delta"), [])
        XCTAssertEqual(try ClaudeSSE.parse(line: ""), [])
        XCTAssertEqual(try ClaudeSSE.parse(line: #"data: {"type":"ping"}"#), [])
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

        XCTAssertEqual(json["model"] as? String, "claude-sonnet-5")
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["max_tokens"] as? Int, 1024)

        // claude-sonnet-5 / claude-opus-5 では 400 になるため送ってはいけないパラメータ（CLAUDE.md の規約）
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
