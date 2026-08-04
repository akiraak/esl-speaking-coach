import Foundation

/// プロバイダ選択 → SentenceTTSClient 生成の一元化（docs/plans/archive/utterance-replay.md）。
/// セッション（TurnBasedVoiceSession）と再読み上げ（UtteranceReplayer）が
/// **同じ既定（Gemini Flash TTS）・同じ voice 写像**を使うため、既定はこの Configuration の
/// 1 箇所だけが持つ。DEBUG の起動引数は override があるときだけ上書きする
/// （ChatRoomStore.currentTTSConfiguration）。
enum SentenceTTSClientFactory {
    /// TTS のプロバイダ選択と各プロバイダの設定の束。
    struct Configuration: Sendable {
        /// 採用構成は Gemini Flash TTS（2026-08-03 に Qwen instruct から戻した）。
        /// キャラの voice / スタイル前置文は `ChatCharacter.speechStyle` が正で、Gemini は
        /// それをそのまま使う（Qwen は voiceMap / instructionMap で写像していた）。
        /// Qwen へは -tts-provider qwen で切り替えられる
        /// （検証記録: docs/plans/archive/alibaba-voice-models.md）
        var provider: TTSProvider = .gemini
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
