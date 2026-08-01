import Foundation

/// プロバイダ選択 → SentenceTTSClient 生成の一元化（docs/plans/utterance-replay.md）。
/// セッション（TurnBasedVoiceSession）と再読み上げ（UtteranceReplayer）が
/// **同じ既定（Qwen instruct）・同じ voice 写像**を使うため、既定はこの Configuration の
/// 1 箇所だけが持つ。DEBUG の起動引数は override があるときだけ上書きする
/// （ChatRoomStore.currentTTSConfiguration）。
enum SentenceTTSClientFactory {
    /// TTS のプロバイダ選択と各プロバイダの設定の束。
    struct Configuration: Sendable {
        /// 採用構成は Qwen TTS instruct（2026-08-01 に Gemini から切替。
        /// docs/plans/archive/alibaba-voice-models.md）。旧既定へは -tts-provider gemini で戻せる
        var provider: TTSProvider = .qwen
        var openAI = OpenAITTSConfiguration()
        var gemini = GeminiTTSConfiguration()
        var qwen = QwenTTSConfiguration()
    }

    static func make(_ configuration: Configuration) -> any SentenceTTSClient {
        switch configuration.provider {
        case .openAI:
            return OpenAITTSClient(configuration: configuration.openAI)
        case .gemini:
            return GeminiTTSClient(configuration: configuration.gemini)
        case .qwen:
            return QwenTTSClient(configuration: configuration.qwen)
        }
    }
}

extension TTSProvider {
    /// 利用量記録（AIUsageEvent）上のプロバイダ種別。
    var usageProvider: AIUsageEvent.Provider {
        switch self {
        case .openAI: return .openai
        case .gemini: return .gemini
        case .qwen: return .alibaba
        }
    }
}
