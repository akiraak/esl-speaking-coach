import XCTest
@testable import EslSpeakingCoach

final class AIPricingTests: XCTestCase {
    /// 導入価格期間内（〜2026-08-31）の sonnet-5 は $2/$10、キャッシュ読み 0.1 倍・書き込み 1.25 倍。
    func testSonnetTurnCostDuringIntroPricing() {
        let event = AIUsageEvent(
            provider: .anthropic, model: "claude-sonnet-5", kind: .conversationTurn,
            inputTokens: 1_000_000, outputTokens: 100_000,
            cacheReadTokens: 1_000_000, cacheWriteTokens: 100_000)
        let date = ISO8601DateFormatter().date(from: "2026-07-25T00:00:00Z")!
        // 入力 $2 + 出力 $1 + キャッシュ読み $0.2 + 書き込み $0.25
        XCTAssertEqual(AIPricing.estimatedCostUSD(for: event, at: date), 3.45, accuracy: 0.0001)
    }

    /// 導入価格終了後は $3/$15 に上がる。
    func testSonnetTurnCostAfterIntroPricing() {
        let event = AIUsageEvent(
            provider: .anthropic, model: "claude-sonnet-5", kind: .conversationTurn,
            inputTokens: 1_000_000, outputTokens: 100_000)
        let date = ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z")!
        XCTAssertEqual(AIPricing.estimatedCostUSD(for: event, at: date), 4.5, accuracy: 0.0001)
    }

    /// opus-5（〜2026-07-31 のフィードバック生成。過去記録の再計算用に単価を残す）は $5/$25。
    func testOpusFeedbackCost() {
        let event = AIUsageEvent(
            provider: .anthropic, model: "claude-opus-5", kind: .sessionFeedback,
            inputTokens: 5_000, outputTokens: 3_000)
        // ai-cost-map.md の概算例: 入力 5K + 出力 3K ≈ $0.10
        XCTAssertEqual(AIPricing.estimatedCostUSD(for: event), 0.1, accuracy: 0.0001)
    }

    /// haiku-4-5（会話の翻訳）は $1/$5。導入価格の期限判定には引っかからない。
    func testHaikuTranslationCost() {
        let event = AIUsageEvent(
            provider: .anthropic, model: "claude-haiku-4-5", kind: .translation,
            inputTokens: 2_000, outputTokens: 1_000)
        let expected = 2_000.0 / 1_000_000 * 1 + 1_000.0 / 1_000_000 * 5
        for iso in ["2026-07-25T00:00:00Z", "2026-10-01T00:00:00Z"] {
            let date = ISO8601DateFormatter().date(from: iso)!
            XCTAssertEqual(
                AIPricing.estimatedCostUSD(for: event, at: date), expected, accuracy: 0.0000001)
        }
    }

    /// STT はトークン優先（音声入力 $6/M + テキスト入力 $2.5/M + 出力 $10/M）。
    func testTranscribeCostWithTokens() {
        let event = AIUsageEvent(
            provider: .openai, model: "gpt-4o-transcribe", kind: .speechToText,
            inputTokens: 100, outputTokens: 50, audioInputTokens: 1_000, audioSeconds: 60)
        let expected = 1_000.0 / 1_000_000 * 6 + 100.0 / 1_000_000 * 2.5 + 50.0 / 1_000_000 * 10
        XCTAssertEqual(AIPricing.estimatedCostUSD(for: event), expected, accuracy: 0.000001)
    }

    /// STT でトークンが取れないときは音声 1 分 ≈ $0.006 で概算する。
    func testTranscribeCostFallsBackToDuration() {
        let event = AIUsageEvent(
            provider: .openai, model: "gpt-4o-transcribe", kind: .speechToText,
            audioSeconds: 60)
        XCTAssertEqual(AIPricing.estimatedCostUSD(for: event), 0.006, accuracy: 0.000001)
    }

    /// gpt-live-transcribe（既定）はトークンではなくセッション音声 $0.017 / 分の分数課金。
    /// tokens 型 usage が混ざっていても分数で計算する
    func testLiveTranscribeCostUsesPerMinuteRate() {
        let event = AIUsageEvent(
            provider: .openai, model: "gpt-live-transcribe", kind: .speechToText,
            inputTokens: 100, outputTokens: 50, audioInputTokens: 1_000, audioSeconds: 90)
        XCTAssertEqual(AIPricing.estimatedCostUSD(for: event), 0.0255, accuracy: 0.000001)
    }

    /// Gemini TTS はトークン優先（入力 $1/M + 音声出力 $20/M）。
    func testGeminiTTSCostWithTokens() {
        let event = AIUsageEvent(
            provider: .gemini, model: "gemini-3.1-flash-tts-preview", kind: .textToSpeech,
            inputTokens: 30, outputTokens: 1_500, audioSeconds: 60)
        let expected = 30.0 / 1_000_000 * 1 + 1_500.0 / 1_000_000 * 20
        // 生成音声 1 分 ≈ $0.03（ai-cost-map.md の目安）
        XCTAssertEqual(AIPricing.estimatedCostUSD(for: event), expected, accuracy: 0.000001)
        XCTAssertEqual(expected, 0.03003, accuracy: 0.0001)
    }

    /// Gemini TTS で usageMetadata が取れないときは秒数 × 25 トークンで概算する。
    func testGeminiTTSCostFallsBackToDuration() {
        let event = AIUsageEvent(
            provider: .gemini, model: "gemini-3.1-flash-tts-preview", kind: .textToSpeech,
            audioSeconds: 60)
        XCTAssertEqual(AIPricing.estimatedCostUSD(for: event), 0.03, accuracy: 0.000001)
    }

    /// OpenAI TTS（聞き比べ用）は音声 1 分 ≈ $0.015 の概算のみ。
    func testOpenAITTSCost() {
        let event = AIUsageEvent(
            provider: .openai, model: "gpt-4o-mini-tts (coral)", kind: .textToSpeech,
            audioSeconds: 120)
        XCTAssertEqual(AIPricing.estimatedCostUSD(for: event), 0.03, accuracy: 0.000001)
    }

    /// 種別内訳表示用の sonnet-5 単価は、導入価格期間中は $2/$10 + 補足あり、
    /// 終了後は $3/$15 + 補足なしに変わる。
    func testCurrentRateReflectsSonnetIntroPricing() {
        let intro = ISO8601DateFormatter().date(from: "2026-07-25T00:00:00Z")!
        let after = ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z")!

        let introRate = AIPricing.currentRate(
            for: .conversationTurn, selection: ModelSelectionSnapshot(), at: intro)
        XCTAssertEqual(introRate.price, "入力 $2 / 出力 $10（1M トークン）")
        XCTAssertNotNil(introRate.note)

        let afterRate = AIPricing.currentRate(
            for: .conversationTurn, selection: ModelSelectionSnapshot(), at: after)
        XCTAssertEqual(afterRate.price, "入力 $3 / 出力 $15（1M トークン）")
        XCTAssertNil(afterRate.note)
    }

    /// **管理画面で選んだモデルに追従する**（既定固定だと切り替えたあと表示と実態がズレる。
    /// 実際に TTS の行が Qwen 固定のまま Gemini 復帰に追随できていなかった）。
    func testCurrentRateFollowsSelection() {
        let selection = ModelSelectionSnapshot(
            claudeModels: [.conversationTurn: .opus5],
            ttsProvider: .qwen,
            sttModel: .transcribe4o)

        let turn = AIPricing.currentRate(for: .conversationTurn, selection: selection)
        XCTAssertEqual(turn.model, "claude-opus-5")
        XCTAssertEqual(turn.price, "入力 $5 / 出力 $25（1M トークン）")
        XCTAssertNil(turn.note, "opus-5 に導入価格は無い")

        // 選んでいない経路は既定のまま
        XCTAssertEqual(
            AIPricing.currentRate(for: .translation, selection: selection).model,
            "claude-haiku-4-5")

        let tts = AIPricing.currentRate(for: .textToSpeech, selection: selection)
        XCTAssertEqual(tts.model, "qwen3-tts-instruct-flash-realtime")
        XCTAssertTrue(tts.price.contains("$0.13"), tts.price)

        let stt = AIPricing.currentRate(for: .speechToText, selection: selection)
        XCTAssertEqual(stt.model, "gpt-4o-transcribe")
    }

    /// 何も選んでいなければ全種別がコード既定のモデルに対応づく
    /// （フィードバック生成は 2026-07-31 に opus-5 → sonnet-5、TTS は 2026-08-03 に Gemini へ復帰）。
    func testCurrentRateMapsAllKindsToDefaultModels() {
        let models = AIUsageEvent.Kind.allCases.map {
            AIPricing.currentRate(for: $0, selection: ModelSelectionSnapshot()).model
        }
        XCTAssertEqual(
            models,
            [
                "gpt-live-transcribe",
                "claude-sonnet-5",
                "gemini-3.1-flash-tts-preview",
                "claude-sonnet-5",
                "claude-sonnet-5",
                "claude-sonnet-5",
                "claude-haiku-4-5",
            ])
    }
}
