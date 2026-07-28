import XCTest
@testable import EslSpeakingCoach

final class TopicSuggestionClientTests: XCTestCase {
    /// 割り当て 2 件（サンプラーを通さず固定値で組む）。
    private let assignments = [
        TopicAssignment(
            genre: TopicGenre(id: "mishaps", english: "mishaps", japanese: "失敗談"),
            style: TopicStyle(id: "recall", english: "recall a past experience", japanese: "思い出"),
            difficulty: .easy),
        TopicAssignment(
            genre: TopicGenre(id: "what-if", english: "what-if situations", japanese: "もしも"),
            style: TopicStyle(id: "imagine", english: "imagine a situation", japanese: "想像する"),
            difficulty: .challenging),
    ]

    func testRequestBodyFollowsProjectRules() throws {
        let data = try TopicSuggestionClient.makeRequestBody(
            recentTitles: ["Planning a trip", "Food you can't quit"], assignments: assignments)
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
        // 候補がどのジャンルとして生成されたかを受け取る（履歴に残して次回の除外に使う）
        let items = try XCTUnwrap(
            (schema["properties"] as? [String: Any])?["topics"] as? [String: Any])
        let itemSchema = try XCTUnwrap(items["items"] as? [String: Any])
        XCTAssertEqual(itemSchema["required"] as? [String], ["title", "hook", "genre"])

        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(
            messages[0]["content"] as? String,
            """
            Recent topics: Planning a trip, Food you can't quit

            Assignments:
            1. genre_id: mishaps | genre: mishaps | angle: recall a past experience | difficulty: easy
            2. genre_id: what-if | genre: what-if situations | angle: imagine a situation | difficulty: slightly challenging
            """)
    }

    /// 補充ぶんの 1 件だけを頼むリクエスト（セッション終了後の持ち越し + 1 件生成）。
    /// 生成件数は割り当ての件数で決まる。
    func testRequestBodyWithSingleAssignment() throws {
        let data = try TopicSuggestionClient.makeRequestBody(
            recentTitles: ["朝のルーティン"], assignments: [assignments[0]])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(
            messages[0]["content"] as? String,
            """
            Recent topics: 朝のルーティン

            Assignments:
            1. genre_id: mishaps | genre: mishaps | angle: recall a past experience | difficulty: easy
            """)
        // system prompt が 3 件固定を要求していないこと（1 件補充が壊れる）
        let system = try XCTUnwrap(json["system"] as? String)
        XCTAssertFalse(system.contains("exactly three"))
        XCTAssertTrue(system.contains("one topic candidate per assignment"))
    }

    func testRequestBodyWithNoRecentTopics() throws {
        let data = try TopicSuggestionClient.makeRequestBody(
            recentTitles: [], assignments: [])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(
            messages[0]["content"] as? String,
            """
            Recent topics: (none)

            Assignments:
            (none)
            """)
    }

    func testParseResponseExtractsTopics() throws {
        let inner = #"{"topics":[{"title":"Morning routines","hook":"What starts your day right?","genre":"sleep"},{"title":"A trip you remember","hook":"Where did you go?","genre":"travel"},{"title":"Comfort food","hook":"What do you eat when tired?","genre":"food"}]}"#
        let response = try JSONSerialization.data(withJSONObject: [
            "content": [["type": "text", "text": inner]],
            "stop_reason": "end_turn",
        ])
        let topics = try TopicSuggestionClient.parseResponse(response)
        XCTAssertEqual(topics.count, 3)
        XCTAssertEqual(topics[0].title, "Morning routines")
        XCTAssertEqual(topics[0].hook, "What starts your day right?")
        XCTAssertEqual(topics[0].genre, "sleep")
    }

    /// 旧形式（genre 無し）の応答でも壊れない。
    func testParseResponseWithoutGenre() throws {
        let inner = #"{"topics":[{"title":"Comfort food","hook":"つかれた日の一皿は？"}]}"#
        let response = try JSONSerialization.data(withJSONObject: [
            "content": [["type": "text", "text": inner]],
            "stop_reason": "end_turn",
        ])
        let topics = try TopicSuggestionClient.parseResponse(response)
        XCTAssertEqual(topics.count, 1)
        XCTAssertNil(topics[0].genre)
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

    /// 非ストリーミング応答の usage フィールドを料金記録用にパースする。
    func testParseUsage() throws {
        let response = try JSONSerialization.data(withJSONObject: [
            "content": [["type": "text", "text": "{}"]],
            "stop_reason": "end_turn",
            "usage": [
                "input_tokens": 300, "output_tokens": 120,
                "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0,
            ],
        ])
        let usage = try XCTUnwrap(TopicSuggestionClient.parseUsage(response))
        XCTAssertEqual(usage.provider, .anthropic)
        XCTAssertEqual(usage.kind, .topicSuggestion)
        XCTAssertEqual(usage.inputTokens, 300)
        XCTAssertEqual(usage.outputTokens, 120)

        let withoutUsage = try JSONSerialization.data(withJSONObject: [
            "content": [], "stop_reason": "end_turn",
        ])
        XCTAssertNil(TopicSuggestionClient.parseUsage(withoutUsage))
    }
}
