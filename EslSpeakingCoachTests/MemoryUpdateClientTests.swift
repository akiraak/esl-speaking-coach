import XCTest
@testable import EslSpeakingCoach

final class MemoryUpdateClientTests: XCTestCase {
    func testRequestBodyFollowsProjectRules() throws {
        let data = try MemoryUpdateClient.makeRequestBody(
            previousNotes: MemoryNotes(
                learner: "About the learner\n- Name is Akira.",
                chobi: "- Adopted a kitten last week."),
            topic: "Free talk",
            transcript: "Learner: I like ramen.\nChobi: Nice!")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        // 記憶更新は sonnet-5 / max_tokens 2500（3 本ぶん）/ ストリーミング
        // （docs/plans/archive/per-character-memory.md）
        XCTAssertEqual(json["model"] as? String, "claude-sonnet-5")
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["max_tokens"] as? Int, 2500)
        // claude-sonnet-5 では 400 になるため送ってはいけないパラメータ
        XCTAssertNil(json["temperature"])
        XCTAssertNil(json["top_p"])
        XCTAssertNil(json["top_k"])

        let outputConfig = try XCTUnwrap(json["output_config"] as? [String: Any])
        XCTAssertEqual(outputConfig["effort"] as? String, "medium")
        let format = try XCTUnwrap(outputConfig["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(schema["required"] as? [String], ["learner", "chobi", "naruko"])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), ["learner", "chobi", "naruko"])

        // system prompt は固定文 + cache_control
        let system = try XCTUnwrap(json["system"] as? [[String: Any]])
        XCTAssertEqual((system[0]["cache_control"] as? [String: Any])?["type"] as? String, "ephemeral")

        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages[0]["content"] as? String)
        XCTAssertTrue(
            content.hasPrefix("Previous memory note about the learner:\nAbout the learner"))
        XCTAssertTrue(
            content.contains("Previous memory note about Chobi:\n- Adopted a kitten last week."))
        XCTAssertTrue(content.contains("Previous memory note about Naruko:\n(none)"))
        XCTAssertTrue(content.contains("Topic of the session that just ended: Free talk"))
        XCTAssertTrue(content.contains("Learner: I like ramen."))
    }

    /// 初回（前回ノートなし）は 3 本とも "(none)" を明示する。
    func testRequestBodyMarksMissingPreviousNotes() throws {
        for blank in [nil, "", "  \n"] as [String?] {
            let data = try MemoryUpdateClient.makeRequestBody(
                previousNotes: MemoryNotes(learner: blank, chobi: blank, naruko: blank),
                topic: "Free talk", transcript: "Learner: Hi.")
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
            let content = try XCTUnwrap(messages[0]["content"] as? String)
            XCTAssertTrue(content.hasPrefix("Previous memory note about the learner:\n(none)"))
            XCTAssertTrue(content.contains("Previous memory note about Chobi:\n(none)"))
            XCTAssertTrue(content.contains("Previous memory note about Naruko:\n(none)"))
        }
    }

    func testParseResultDecodesThreeNotes() throws {
        let text = #"""
        {"learner":"About the learner\n- Name is Akira.\n\nRecent sessions\n- Talked about ramen shops.",\#
        "chobi":"- Adopted a kitten named Mugi.","naruko":"- Promised to try a new ramen shop."}
        """#
        let notes = try MemoryUpdateClient.parseResult(text: text, stopReason: "end_turn")
        XCTAssertTrue(notes.learner.hasPrefix("About the learner"))
        XCTAssertTrue(notes.learner.contains("Talked about ramen shops."))
        XCTAssertEqual(notes.chobi, "- Adopted a kitten named Mugi.")
        XCTAssertEqual(notes.naruko, "- Promised to try a new ramen shop.")
    }

    /// キャラが今回自分の話をしなかったときは空文字で返る = nil（呼び出し側で前回ノートを維持）。
    func testParseResultTreatsEmptyCharacterNoteAsKeepPrevious() throws {
        let text = #"{"learner":"About the learner\n- Name is Akira.","chobi":"","naruko":"  \n"}"#
        let notes = try MemoryUpdateClient.parseResult(text: text, stopReason: "end_turn")
        XCTAssertFalse(notes.learner.isEmpty)
        XCTAssertNil(notes.chobi)
        XCTAssertNil(notes.naruko)
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

    /// max_tokens 打ち切り等で JSON が途切れた場合はエラー（3 本とも前回ノートを維持する）。
    func testParseResultThrowsOnTruncatedJSON() {
        XCTAssertThrowsError(
            try MemoryUpdateClient.parseResult(
                text: #"{"learner":"About the le"#, stopReason: "max_tokens"))
    }

    /// 学習者ノートが空だとローリング記憶が消えるためエラー扱い（前回ノートを維持する）。
    func testParseResultThrowsOnEmptyLearnerNote() {
        XCTAssertThrowsError(
            try MemoryUpdateClient.parseResult(
                text: #"{"learner":"  \n","chobi":"- Has a kitten.","naruko":""}"#,
                stopReason: "end_turn"))
    }
}
