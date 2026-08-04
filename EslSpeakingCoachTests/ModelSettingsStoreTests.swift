import XCTest
@testable import EslSpeakingCoach

/// 経路ごとのモデル選択の保存（docs/plans/model-selection-in-admin.md Phase 2）。
@MainActor
final class ModelSettingsStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "ModelSettingsStoreTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// 未設定ならコード側の既定（翻訳だけ haiku、他は sonnet）。
    func testUnsetRoutesUseCodeDefaults() {
        let store = ModelSettingsStore(defaults: defaults)
        XCTAssertEqual(store.model(for: .conversationTurn), .sonnet5)
        XCTAssertEqual(store.model(for: .translation), .haiku45)
        XCTAssertTrue(store.overriddenRoutes.isEmpty)
    }

    /// 選択は別インスタンス（= アプリ再起動）でも残る。
    func testSelectionSurvivesReload() {
        ModelSettingsStore(defaults: defaults).setModel(.opus5, for: .conversationTurn)

        let reloaded = ModelSettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.model(for: .conversationTurn), .opus5)
        XCTAssertEqual(reloaded.overriddenRoutes, [.conversationTurn])
        // 他の経路は巻き込まない
        XCTAssertEqual(reloaded.model(for: .sessionFeedback), .sonnet5)
    }

    /// 既定と同じ選択は保存しない（あとで既定が変わったら自動で追従させるため）。
    func testChoosingDefaultClearsTheStoredValue() {
        let store = ModelSettingsStore(defaults: defaults)
        store.setModel(.opus5, for: .memoryUpdate)
        XCTAssertNotNil(defaults.string(forKey: ModelSettingsStore.key(for: .memoryUpdate)))

        store.setModel(.sonnet5, for: .memoryUpdate)
        XCTAssertNil(defaults.string(forKey: ModelSettingsStore.key(for: .memoryUpdate)))
        XCTAssertEqual(store.model(for: .memoryUpdate), .sonnet5)
    }

    /// 廃止したモデル名が残っていても落ちず、既定へ倒す。
    func testUnknownStoredValueFallsBackToDefault() {
        defaults.set("claude-opus-4-1", forKey: ModelSettingsStore.key(for: .topicSuggestion))
        let store = ModelSettingsStore(defaults: defaults)
        XCTAssertEqual(store.model(for: .topicSuggestion), .sonnet5)
    }

    func testResetToDefaultsClearsEveryRoute() {
        let store = ModelSettingsStore(defaults: defaults)
        store.setModel(.opus5, for: .conversationTurn)
        store.setModel(.sonnet5, for: .translation)
        store.setTTSProvider(.qwen)
        store.setSTTModel(.transcribe4o)
        XCTAssertEqual(Set(store.overriddenRoutes), [.conversationTurn, .translation])
        XCTAssertEqual(store.overriddenCount, 4)

        store.resetToDefaults()
        XCTAssertEqual(store.overriddenCount, 0)
        XCTAssertEqual(store.ttsProvider, .gemini)
        XCTAssertEqual(store.sttModel, .live)
        XCTAssertTrue(store.overriddenRoutes.isEmpty)
        XCTAssertEqual(store.model(for: .conversationTurn), .sonnet5)
        XCTAssertEqual(store.model(for: .translation), .haiku45)
    }

    // MARK: - 音声（TTS / STT）

    /// 未設定なら音声 2 経路もコード既定。**既定はコード側（構成の既定値）と一致していること**。
    func testVoiceRoutesUseCodeDefaults() {
        let store = ModelSettingsStore(defaults: defaults)
        XCTAssertEqual(store.ttsProvider, .gemini)
        XCTAssertEqual(store.sttModel, .live)
        XCTAssertEqual(SentenceTTSClientFactory.Configuration().provider, TTSProvider.default)
        XCTAssertEqual(OpenAITranscriptionConfiguration().model, STTModel.default.rawValue)
    }

    func testVoiceSelectionSurvivesReload() {
        let store = ModelSettingsStore(defaults: defaults)
        store.setTTSProvider(.qwen)
        store.setSTTModel(.transcribe4o)

        let reloaded = ModelSettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.ttsProvider, .qwen)
        XCTAssertEqual(reloaded.sttModel, .transcribe4o)
        XCTAssertEqual(reloaded.overriddenCount, 2)
    }

    /// 廃止・未知のプロバイダ名やモデル名が残っていても既定へ倒す。
    func testVoiceUnknownStoredValuesFallBackToDefaults() {
        defaults.set("elevenlabs", forKey: ModelSettingsStore.ttsKey)
        defaults.set("whisper-1", forKey: ModelSettingsStore.sttKey)
        let store = ModelSettingsStore(defaults: defaults)
        XCTAssertEqual(store.ttsProvider, .default)
        XCTAssertEqual(store.sttModel, .default)
        XCTAssertEqual(store.overriddenCount, 0)
    }

    /// 既定と同じ選択は音声側も保存しない。
    func testChoosingVoiceDefaultClearsTheStoredValue() {
        let store = ModelSettingsStore(defaults: defaults)
        store.setTTSProvider(.qwen)
        XCTAssertNotNil(defaults.string(forKey: ModelSettingsStore.ttsKey))
        store.setTTSProvider(.gemini)
        XCTAssertNil(defaults.string(forKey: ModelSettingsStore.ttsKey))
    }

    /// 診断ログ 1 行に全 7 経路が出る（あとから「どの構成のセッションか」を辿れるように）。
    func testSnapshotSummarizesEveryRoute() {
        let store = ModelSettingsStore(defaults: defaults)
        store.setModel(.opus5, for: .conversationTurn)
        store.setTTSProvider(.qwen)

        let summary = store.snapshot().diagnosticsSummary
        XCTAssertTrue(summary.contains("turn=claude-opus-5"), summary)
        XCTAssertTrue(summary.contains("translation=claude-haiku-4-5"), summary)
        XCTAssertTrue(summary.contains("tts=qwen3-tts-instruct-flash-realtime"), summary)
        XCTAssertTrue(summary.contains("stt=gpt-live-transcribe"), summary)
    }

    /// 保存キーは課金経路の rawValue に揃える（料金画面・音声 2 経路と同じ形）。
    func testKeysFollowUsageKindRawValues() {
        XCTAssertEqual(ModelSettingsStore.key(for: .conversationTurn), "model.turn")
        XCTAssertEqual(ModelSettingsStore.key(for: .translation), "model.translation")
        XCTAssertEqual(ModelSettingsStore.ttsKey, "model.tts")
        XCTAssertEqual(ModelSettingsStore.sttKey, "model.stt")
        XCTAssertEqual(
            Set(ClaudeRoute.allCases.map(\.kind)),
            [.conversationTurn, .topicSuggestion, .sessionFeedback, .memoryUpdate, .translation])
    }
}
