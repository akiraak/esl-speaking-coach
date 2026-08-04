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
        /// Qwen へは管理画面「モデル」か -tts-provider qwen で切り替えられる
        /// （検証記録: docs/plans/archive/alibaba-voice-models.md）
        var provider: TTSProvider = .default
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
    /// **TTS 既定の単一の正**（`SentenceTTSClientFactory.Configuration.provider` の既定値もここを見る）。
    static let `default` = TTSProvider.gemini

    /// 接続に要る API キーの Keychain アカウント。
    var keychainAccount: String {
        switch self {
        case .openAI: return KeychainStore.openAIAPIKeyAccount
        case .gemini: return KeychainStore.geminiAPIKeyAccount
        case .qwen: return KeychainStore.dashScopeAPIKeyAccount
        }
    }

    /// いま使うモデル名（料金画面・診断ログの表示用）。各プロバイダ設定の既定値が正。
    var modelDescription: String {
        switch self {
        case .openAI: return OpenAITTSConfiguration().model
        case .gemini: return GeminiTTSConfiguration().model
        case .qwen: return QwenTTSConfiguration().model
        }
    }

    /// 管理画面に出す挙動の違い。
    var note: String {
        switch self {
        case .gemini:
            return "独立した instructions フィールドが無いため、本文先頭にスタイル指示を前置する"
        case .qwen:
            return "voice とスタイル指示を Qwen の voice 名へ写像する。接続を張りっぱなしにする"
        case .openAI:
            return "固定 voice で読む（聞き比べ用の経路）"
        }
    }

    /// 利用量記録（AIUsageEvent）上のプロバイダ種別。
    var usageProvider: AIUsageEvent.Provider {
        switch self {
        case .openAI: return .openai
        case .gemini: return .gemini
        case .qwen: return .alibaba
        }
    }
}
