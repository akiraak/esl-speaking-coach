import XCTest
@testable import EslSpeakingCoach

final class SessionFeedbackClientTests: XCTestCase {
    func testRequestBodyFollowsProjectRules() throws {
        let data = try SessionFeedbackClient.makeRequestBody(
            topic: "Free talk", transcript: "Learner: I like ramen.\nChobi: Nice!")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        // フィードバック生成は opus-5 / effort high / max_tokens 16000+ / ストリーミング（CLAUDE.md）
        XCTAssertEqual(json["model"] as? String, "claude-opus-5")
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["max_tokens"] as? Int, 16000)
        // claude-opus-5 では 400 になるため送ってはいけないパラメータ
        XCTAssertNil(json["temperature"])
        XCTAssertNil(json["top_p"])
        XCTAssertNil(json["top_k"])

        let outputConfig = try XCTUnwrap(json["output_config"] as? [String: Any])
        XCTAssertEqual(outputConfig["effort"] as? String, "high")
        let format = try XCTUnwrap(outputConfig["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(
            Set(schema["required"] as? [String] ?? []),
            ["summary", "corrections", "try_phrases"])

        // system prompt は固定文 + cache_control
        let system = try XCTUnwrap(json["system"] as? [[String: Any]])
        XCTAssertEqual((system[0]["cache_control"] as? [String: Any])?["type"] as? String, "ephemeral")

        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages[0]["content"] as? String)
        XCTAssertTrue(content.hasPrefix("Topic: Free talk"))
        XCTAssertTrue(content.contains("Learner: I like ramen."))
    }

    /// 単語モードは 1 行目だけを `Practice word:` に差し替える（system prompt は共通 = キャッシュ維持）。
    func testWordModeUsesPracticeWordLabel() throws {
        let transcript = "Learner: I finally got around to it.\nChobi: Nice!"
        let data = try SessionFeedbackClient.makeRequestBody(
            kind: .word, topic: "get around to", transcript: transcript)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages[0]["content"] as? String)
        XCTAssertTrue(content.hasPrefix("Practice word: get around to"))
        XCTAssertFalse(content.contains("Topic:"))
        XCTAssertTrue(content.contains(transcript))

        let system = try XCTUnwrap(json["system"] as? [[String: Any]])
        XCTAssertEqual(system[0]["text"] as? String, SessionFeedbackClient.systemPrompt)
    }

    func testParseResultDecodesFeedback() throws {
        let text = """
        {"summary":"今日はたくさん話せましたね。次は過去形を意識してみましょう。",\
        "corrections":[{"original":"I go to Okinawa last month",\
        "improved":"I went to Okinawa last month","note":"過去の話は過去形で"}],\
        "try_phrases":[{"phrase":"It was totally worth it.","meaning":"行く価値があった"}]}
        """
        let feedback = try SessionFeedbackClient.parseResult(text: text, stopReason: "end_turn")
        XCTAssertEqual(feedback.corrections.count, 1)
        XCTAssertEqual(feedback.corrections[0].improved, "I went to Okinawa last month")
        XCTAssertEqual(feedback.tryPhrases[0].meaning, "行く価値があった")
        XCTAssertTrue(feedback.summary.hasPrefix("今日は"))
    }

    /// refusal はテキストを読む前に判定する（CLAUDE.md の規約）。
    func testParseResultThrowsOnRefusal() {
        XCTAssertThrowsError(
            try SessionFeedbackClient.parseResult(text: "", stopReason: "refusal")
        ) { error in
            guard case SessionFeedbackError.refusal = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    /// max_tokens 打ち切り等で JSON が途切れた場合はエラー。
    func testParseResultThrowsOnTruncatedJSON() {
        XCTAssertThrowsError(
            try SessionFeedbackClient.parseResult(
                text: #"{"summary":"Good job","corrections":[{"orig"#, stopReason: "max_tokens"))
    }
}
