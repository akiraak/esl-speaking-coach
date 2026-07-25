import Foundation

/// 発話ごとの読み上げスタイル（キャラの voice とスタイル前置文）。
/// 2 キャラ台本では発話単位で ChatCharacter.speechStyle を渡す。
struct SpeechStyle: Sendable, Equatable {
    /// Gemini TTS の voice 名（Leda / Aoede 等）。OpenAI TTS は voice 体系が異なるため参照しない
    var voice: String
    /// 話し方を制御する自然文の前置指示
    var styleInstruction: String
}

/// 文単位 TTS の内部境界。VoiceSession 境界（CLAUDE.md）とは別に、
/// TTS 単体の差し替え（OpenAI ⇔ Gemini ⇔ 将来の Cartesia 等）をこの裏で行う。
protocol SentenceTTSClient: Sendable {
    /// 表示用のモデル名。
    var modelDescription: String { get }
    /// 1 文ぶんの音声を PCM16 24kHz mono LE のチャンク列としてストリーミング取得する。
    func streamPCM(apiKey: String, text: String, style: SpeechStyle) -> AsyncThrowingStream<Data, Error>
}

/// 選択できる TTS プロバイダ（採用は Gemini。OpenAI は聞き比べ用）。
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
