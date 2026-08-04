import XCTest
@testable import EslSpeakingCoach

/// STT / TTS の選択が音声パイプラインの構成へ正しく効くこと
/// （docs/plans/model-selection-in-admin.md Phase 3）。
final class VoiceModelSelectionTests: XCTestCase {
    /// STT はモデルを変えると **VAD の方式とマイクのサンプルレートごと**変わる。
    func testSTTSelectionDrivesTranscriptionBehaviour() {
        var config = OpenAITranscriptionConfiguration()

        config.model = STTModel.live.rawValue
        XCTAssertTrue(config.usesClientEndpointing, "live はクライアント VAD + 手動 commit")
        XCTAssertFalse(config.isQwenASR)
        XCTAssertEqual(config.micSampleRate, 24000)

        config.model = STTModel.transcribe4o.rawValue
        XCTAssertFalse(config.usesClientEndpointing, "4o はサーバ VAD")
        XCTAssertFalse(config.isLiveTranscribe)
        XCTAssertEqual(config.micSampleRate, 24000)

        config.model = STTModel.qwenASR.rawValue
        XCTAssertTrue(config.isQwenASR)
        XCTAssertTrue(config.usesClientEndpointing)
        XCTAssertEqual(config.micSampleRate, 16000, "Qwen3-ASR は 16kHz へ落とす")
    }

    /// プロバイダごとに要る API キーが違う（未設定バッジの根拠）。
    func testKeychainAccountsPerProvider() {
        XCTAssertEqual(TTSProvider.gemini.keychainAccount, KeychainStore.geminiAPIKeyAccount)
        XCTAssertEqual(TTSProvider.qwen.keychainAccount, KeychainStore.dashScopeAPIKeyAccount)
        XCTAssertEqual(TTSProvider.openAI.keychainAccount, KeychainStore.openAIAPIKeyAccount)
        XCTAssertEqual(STTModel.live.keychainAccount, KeychainStore.openAIAPIKeyAccount)
        XCTAssertEqual(STTModel.transcribe4o.keychainAccount, KeychainStore.openAIAPIKeyAccount)
        XCTAssertEqual(STTModel.qwenASR.keychainAccount, KeychainStore.dashScopeAPIKeyAccount)
    }

    /// 選んだプロバイダのクライアントが生成され、利用記録のプロバイダ種別も一致すること
    /// （ここがずれると別プロバイダの単価で課金推定してしまう）。
    func testTTSSelectionPicksClientAndUsageProvider() {
        var configuration = SentenceTTSClientFactory.Configuration()

        configuration.provider = .gemini
        XCTAssertEqual(
            SentenceTTSClientFactory.make(configuration).modelDescription,
            GeminiTTSConfiguration().model)
        XCTAssertEqual(TTSProvider.gemini.usageProvider, .gemini)

        configuration.provider = .qwen
        XCTAssertEqual(
            SentenceTTSClientFactory.make(configuration).modelDescription,
            QwenTTSConfiguration().model)
        XCTAssertEqual(TTSProvider.qwen.usageProvider, .alibaba)

        configuration.provider = .openAI
        XCTAssertEqual(TTSProvider.openAI.usageProvider, .openai)
    }

    /// 単価の表示は AIPricing から引く（画面側で単価を二重管理しない）。
    func testPriceDescriptionsComeFromPricingTable() {
        XCTAssertEqual(AIPricing.priceDescription(for: .live), "音声 $0.017 / 分（発話セグメント分のみ）")
        XCTAssertTrue(AIPricing.priceDescription(for: STTModel.qwenASR).contains("$0.0054"))
        // Gemini TTS は音声出力トークン単価（$20 / 1M・25 トークン/秒）から 1 分 ≈ $0.03
        XCTAssertTrue(AIPricing.priceDescription(for: TTSProvider.gemini).contains("$0.03"))
        XCTAssertTrue(AIPricing.priceDescription(for: TTSProvider.qwen).contains("$0.13"))
    }
}
