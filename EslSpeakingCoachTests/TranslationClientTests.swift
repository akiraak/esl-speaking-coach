import XCTest
@testable import EslSpeakingCoach

final class TranslationClientTests: XCTestCase {
    private let targetID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let otherID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func makeBody(
        topic: String? = "Morning routines",
        context: [TranslationClient.ContextLine] = [],
        targets: [TranslationClient.Item]? = nil
    ) throws -> [String: Any] {
        let data = try TranslationClient.makeRequestBody(
            topic: topic, context: context,
            targets: targets ?? [
                TranslationClient.Item(id: targetID, speaker: "Chobi", text: "That sounds fun!")
            ])
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testRequestBodyFollowsProjectRules() throws {
        let json = try makeBody()

        // 短文の英日翻訳は haiku（$1 / $5）で十分（docs/plans/message-translation.md）
        XCTAssertEqual(json["model"] as? String, "claude-haiku-4-5")
        XCTAssertEqual(json["max_tokens"] as? Int, 4096)
        // claude-haiku-4-5 では effort が 400 になるため送ってはいけない
        let outputConfig = try XCTUnwrap(json["output_config"] as? [String: Any])
        XCTAssertNil(outputConfig["effort"])
        // 従来どおりサンプリングパラメータも送らない
        XCTAssertNil(json["temperature"])
        XCTAssertNil(json["top_p"])
        XCTAssertNil(json["top_k"])

        // structured outputs で [{id, ja}] を受け取る
        let format = try XCTUnwrap(outputConfig["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(schema["required"] as? [String], ["translations"])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let array = try XCTUnwrap(properties["translations"] as? [String: Any])
        let items = try XCTUnwrap(array["items"] as? [String: Any])
        XCTAssertEqual(items["required"] as? [String], ["id", "ja"])

        // system prompt は固定文（キャッシュ最小プレフィックスに届かないので cache_control は付けない）
        XCTAssertEqual(json["system"] as? String, TranslationClient.systemPrompt)
    }

    /// 文脈（トピック + 直前発話）が本文に含まれ、文脈側の発話には id が振られていないこと。
    func testRequestBodyCarriesContextWithoutIDs() throws {
        let json = try makeBody(context: [
            TranslationClient.ContextLine(speaker: "Learner", text: "I went to Kyoto."),
            TranslationClient.ContextLine(speaker: "Naruko", text: "Oh, when?"),
        ])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages[0]["content"] as? String)

        XCTAssertTrue(content.contains("Topic: Morning routines"))
        XCTAssertTrue(content.contains("Learner: I went to Kyoto."))
        XCTAssertTrue(content.contains("Naruko: Oh, when?"))
        // 訳出対象は id 付きの 1 行だけ
        XCTAssertTrue(content.contains("[\(targetID.uuidString)] Chobi: That sounds fun!"))
        XCTAssertFalse(content.contains("[\(targetID.uuidString)] Learner: I went to Kyoto."))
        // 文脈行に UUID が混ざっていない（対象は 1 件なので UUID の出現も 1 回）
        XCTAssertEqual(
            content.components(separatedBy: targetID.uuidString).count - 1, 1)
    }

    /// 文脈が無い（セッション先頭）とトピック未確定は "(none)" で明示する。
    func testRequestBodyMarksMissingContextAndTopic() throws {
        for topic in [nil, "", "  \n"] as [String?] {
            let json = try makeBody(topic: topic)
            let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
            let content = try XCTUnwrap(messages[0]["content"] as? String)
            XCTAssertTrue(content.hasPrefix("Topic: (none)"))
            XCTAssertTrue(content.contains("do not translate):\n(none)"))
        }
    }

    func testParseResponseMapsIDsToTranslations() throws {
        let inner = """
        {"translations":[\
        {"id":"\(targetID.uuidString)","ja":"それは楽しそう！"},\
        {"id":"\(otherID.uuidString)","ja":"いつ行ったの？"}]}
        """
        let data = try responseJSON(text: inner, stopReason: "end_turn")
        let translations = try TranslationClient.parseResponse(data)
        XCTAssertEqual(translations[targetID], "それは楽しそう！")
        XCTAssertEqual(translations[otherID], "いつ行ったの？")
    }

    /// 未知の id・空文字は捨てる（対応が取れる分だけ採用する）。
    func testParseResponseSkipsUnusableEntries() throws {
        let inner = """
        {"translations":[\
        {"id":"not-a-uuid","ja":"無効"},\
        {"id":"\(otherID.uuidString)","ja":"  "},\
        {"id":"\(targetID.uuidString)","ja":" それは楽しそう！ "}]}
        """
        let data = try responseJSON(text: inner, stopReason: "end_turn")
        let translations = try TranslationClient.parseResponse(data)
        XCTAssertEqual(translations, [targetID: "それは楽しそう！"])
    }

    /// refusal はテキストを読む前に判定する（CLAUDE.md の規約）。
    func testParseResponseThrowsOnRefusal() throws {
        // content が空でもクラッシュせず throw すること
        let data = try XCTUnwrap(#"{"stop_reason":"refusal","content":[]}"#.data(using: .utf8))
        XCTAssertThrowsError(try TranslationClient.parseResponse(data)) { error in
            guard case TranslationError.refusal = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    /// 1 件も対応が取れなければエラー（未翻訳のまま次のフラッシュへ回す）。
    func testParseResponseThrowsOnEmptyResult() throws {
        let data = try responseJSON(text: #"{"translations":[]}"#, stopReason: "end_turn")
        XCTAssertThrowsError(try TranslationClient.parseResponse(data))
    }

    func testParseUsageRecordsTranslationKind() throws {
        let data = try responseJSON(
            text: #"{"translations":[]}"#, stopReason: "end_turn",
            usage: ["input_tokens": 420, "output_tokens": 95])
        let usage = try XCTUnwrap(TranslationClient.parseUsage(data))
        XCTAssertEqual(usage.kind, .translation)
        XCTAssertEqual(usage.provider, .anthropic)
        XCTAssertEqual(usage.model, "claude-haiku-4-5")
        XCTAssertEqual(usage.inputTokens, 420)
        XCTAssertEqual(usage.outputTokens, 95)
    }

    // MARK: - private

    /// structured outputs の応答（content[0].text に JSON 文字列が入る形）を組み立てる。
    private func responseJSON(
        text: String, stopReason: String, usage: [String: Any]? = nil
    ) throws -> Data {
        let block: [String: Any] = ["type": "text", "text": text]
        var payload: [String: Any] = ["stop_reason": stopReason, "content": [block]]
        if let usage { payload["usage"] = usage }
        return try JSONSerialization.data(withJSONObject: payload)
    }
}
