import XCTest
@testable import EslSpeakingCoach

/// 選んだモデルがリクエストボディと利用記録に乗ること、
/// **effort 非対応のモデル（haiku-4-5）では effort を送らないこと**を確かめる
/// （送ると 400 になる。docs/plans/model-selection-in-admin.md Phase 2）。
final class ClaudeModelSelectionTests: XCTestCase {
    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func outputConfig(_ body: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(body["output_config"] as? [String: Any])
    }

    // MARK: - 会話ターン

    func testTurnBodyUsesSelectedModelAndEffort() throws {
        let body = try json(
            ClaudeMessagesClient.makeRequestBody(
                parameters: .init(model: .opus5), system: "sys",
                messages: [ConversationMessage(role: .user, text: "hi")]))

        XCTAssertEqual(body["model"] as? String, "claude-opus-5")
        XCTAssertEqual(try outputConfig(body)["effort"] as? String, "low")
        // thinking と本文で予算を共有するため opus-5 は 1024 では足りない
        XCTAssertEqual(body["max_tokens"] as? Int, 4096)
    }

    func testTurnBodyDropsOutputConfigForModelWithoutEffort() throws {
        let body = try json(
            ClaudeMessagesClient.makeRequestBody(
                parameters: .init(model: .haiku45), system: "sys",
                messages: [ConversationMessage(role: .user, text: "hi")]))

        XCTAssertEqual(body["model"] as? String, "claude-haiku-4-5")
        XCTAssertNil(body["output_config"], "haiku-4-5 に effort を送ると 400 になる")
        XCTAssertEqual(body["max_tokens"] as? Int, 1024)
    }

    // MARK: - structured outputs を使う 4 経路

    func testTopicBodyKeepsSchemaAndDropsEffortForHaiku() throws {
        let assignments = [
            TopicAssignment(
                genre: TopicGenre(id: "mishaps", english: "mishaps", japanese: "失敗談"),
                style: TopicStyle(id: "recall", english: "recall", japanese: "思い出"),
                difficulty: .easy)
        ]
        let body = try json(
            TopicSuggestionClient.makeRequestBody(
                model: .haiku45, recentTitles: [], assignments: assignments))

        XCTAssertEqual(body["model"] as? String, "claude-haiku-4-5")
        let config = try outputConfig(body)
        XCTAssertNil(config["effort"])
        XCTAssertNotNil(config["format"], "structured outputs は残す")
    }

    func testFeedbackBodyUsesSelectedModel() throws {
        let sonnet = try json(
            SessionFeedbackClient.makeRequestBody(
                model: .sonnet5, topic: "Trip", transcript: "Learner: hi"))
        XCTAssertEqual(sonnet["model"] as? String, "claude-sonnet-5")
        XCTAssertEqual(try outputConfig(sonnet)["effort"] as? String, "high")

        let haiku = try json(
            SessionFeedbackClient.makeRequestBody(
                model: .haiku45, topic: "Trip", transcript: "Learner: hi"))
        XCTAssertEqual(haiku["model"] as? String, "claude-haiku-4-5")
        XCTAssertNil(try outputConfig(haiku)["effort"])
        XCTAssertNotNil(try outputConfig(haiku)["format"])
    }

    func testMemoryBodyUsesSelectedModel() throws {
        let body = try json(
            MemoryUpdateClient.makeRequestBody(
                model: .opus5, previousMemory: nil, topic: "Trip", transcript: "Learner: hi"))
        XCTAssertEqual(body["model"] as? String, "claude-opus-5")
        XCTAssertEqual(try outputConfig(body)["effort"] as? String, "medium")
    }

    /// 翻訳はモデルを問わず effort を送らない（経路の設定が nil）。
    func testTranslationBodyNeverSendsEffort() throws {
        for model in ClaudeModel.allCases {
            let body = try json(
                TranslationClient.makeRequestBody(
                    model: model, topic: nil, context: [],
                    targets: [.init(id: UUID(), speaker: "Chobi", text: "Hello")]))
            XCTAssertEqual(body["model"] as? String, model.rawValue)
            XCTAssertNil(try outputConfig(body)["effort"], "\(model.rawValue) で effort を送っている")
            XCTAssertNotNil(try outputConfig(body)["format"])
        }
    }

    // MARK: - 利用記録

    /// 記録側のモデル名もリクエストと同じでないと、料金の推定が別モデルの単価になる。
    func testUsageRecordsTheSelectedModel() throws {
        let response = Data(#"{"usage":{"input_tokens":10,"output_tokens":5}}"#.utf8)

        let topic = try XCTUnwrap(TopicSuggestionClient.parseUsage(response, model: .opus5))
        XCTAssertEqual(topic.model, "claude-opus-5")
        XCTAssertEqual(topic.kind, .topicSuggestion)

        let translation = try XCTUnwrap(TranslationClient.parseUsage(response, model: .sonnet5))
        XCTAssertEqual(translation.model, "claude-sonnet-5")
        XCTAssertEqual(translation.kind, .translation)
    }

    // MARK: - 経路の定義

    /// 課金経路（料金画面の種別）と 1:1 で対応していること。
    func testRoutesMapOntoUsageKinds() {
        XCTAssertEqual(ClaudeRoute.allCases.count, 5)
        XCTAssertEqual(Set(ClaudeRoute.allCases.map(\.kind)).count, 5)
        XCTAssertEqual(ClaudeRoute.conversationTurn.title, AIUsageEvent.Kind.conversationTurn.label)
    }

    /// キャッシュ最小プレフィックスは 2026-08-03 時点の各モデルの値
    /// （会話ターンの台本 約 2,000 トークンは haiku-4-5 では効かない）。
    func testCacheMinimumPromptTokens() {
        XCTAssertEqual(ClaudeModel.opus5.cacheMinimumPromptTokens, 512)
        XCTAssertEqual(ClaudeModel.sonnet5.cacheMinimumPromptTokens, 1024)
        XCTAssertEqual(ClaudeModel.haiku45.cacheMinimumPromptTokens, 4096)
        let turnTokens = try? XCTUnwrap(ClaudeRoute.conversationTurn.approximateSystemPromptTokens)
        XCTAssertEqual(turnTokens, 2_000)
        XCTAssertLessThan(turnTokens ?? 0, ClaudeModel.haiku45.cacheMinimumPromptTokens)
        XCTAssertGreaterThan(turnTokens ?? 0, ClaudeModel.sonnet5.cacheMinimumPromptTokens)
    }
}
