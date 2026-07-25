import Foundation

/// 案 A2 の文単位 TTS の内部境界。VoiceSession 境界（CLAUDE.md）とは別に、
/// TTS 単体の差し替え（OpenAI ⇔ Gemini ⇔ 将来の Cartesia 等）をこの裏で行う（Phase 3 の代替比較）。
protocol SentenceTTSClient: Sendable {
    /// 表示用の "モデル名 (voice)"。
    var voiceDescription: String { get }
    /// 1 文ぶんの音声を PCM16 24kHz mono LE のチャンク列としてストリーミング取得する。
    func streamPCM(apiKey: String, text: String) -> AsyncThrowingStream<Data, Error>
}

/// 案 A2 で選択できる TTS プロバイダ。
enum TTSProvider: String, CaseIterable, Identifiable, Sendable {
    case openAI = "openai"
    case gemini = "gemini"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openAI: return "OpenAI TTS"
        case .gemini: return "Gemini TTS"
        }
    }
}
