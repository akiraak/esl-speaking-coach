import XCTest
@testable import EslSpeakingCoach

final class MemoryUpdateClientTests: XCTestCase {
    func testRequestBodyFollowsProjectRules() throws {
        let data = try MemoryUpdateClient.makeRequestBody(
            previousMemory: "About the learner\n- Name is Akira.",
            topic: "Free talk",
            transcript: "Learner: I like ramen.\nChobi: Nice!")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        // 記憶更新は sonnet-5 / max_tokens 2000 / ストリーミング（docs/plans/character-memory.md）
        XCTAssertEqual(json["model"] as? String, "claude-sonnet-5")
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["max_tokens"] as? Int, 2000)
        // claude-sonnet-5 では 400 になるため送ってはいけないパラメータ
        XCTAssertNil(json["temperature"])
        XCTAssertNil(json["top_p"])
        XCTAssertNil(json["top_k"])

        let outputConfig = try XCTUnwrap(json["output_config"] as? [String: Any])
        XCTAssertEqual(outputConfig["effort"] as? String, "medium")
        let format = try XCTUnwrap(outputConfig["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(schema["required"] as? [String], ["memory"])

        // system prompt は固定文 + cache_control
        let system = try XCTUnwrap(json["system"] as? [[String: Any]])
        XCTAssertEqual((system[0]["cache_control"] as? [String: Any])?["type"] as? String, "ephemeral")

        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages[0]["content"] as? String)
        XCTAssertTrue(content.hasPrefix("Previous memory note:\nAbout the learner"))
        XCTAssertTrue(content.contains("Topic of the session that just ended: Free talk"))
        XCTAssertTrue(content.contains("Learner: I like ramen."))
    }

    /// 初回（前回ノートなし）は "(none)" を明示する。
    func testRequestBodyMarksMissingPreviousMemory() throws {
        for previous in [nil, "", "  \n"] as [String?] {
            let data = try MemoryUpdateClient.makeRequestBody(
                previousMemory: previous, topic: "Free talk", transcript: "Learner: Hi.")
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
            let content = try XCTUnwrap(messages[0]["content"] as? String)
            XCTAssertTrue(content.hasPrefix("Previous memory note:\n(none)"))
        }
    }

    func testParseResultDecodesMemory() throws {
        let text = #"{"memory":"About the learner\n- Name is Akira.\n\nRecent sessions\n- Talked about ramen shops."}"#
        let memory = try MemoryUpdateClient.parseResult(text: text, stopReason: "end_turn")
        XCTAssertTrue(memory.hasPrefix("About the learner"))
        XCTAssertTrue(memory.contains("Talked about ramen shops."))
    }

    /// refusal はテキストを読む前に判定する（CLAUDE.md の規約）。
    func testParseResultThrowsOnRefusal() {
        XCTAssertThrowsError(
            try MemoryUpdateClient.parseResult(text: "", stopReason: "refusal")
        ) { error in
            guard case MemoryUpdateError.refusal = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    /// max_tokens 打ち切り等で JSON が途切れた場合はエラー（前回ノートを維持する）。
    func testParseResultThrowsOnTruncatedJSON() {
        XCTAssertThrowsError(
            try MemoryUpdateClient.parseResult(
                text: #"{"memory":"About the le"#, stopReason: "max_tokens"))
    }

    /// 空ノートはローリング記憶を消してしまうためエラー扱い（前回ノートを維持する）。
    func testParseResultThrowsOnEmptyMemory() {
        XCTAssertThrowsError(
            try MemoryUpdateClient.parseResult(text: #"{"memory":"  \n"}"#, stopReason: "end_turn"))
    }
}
