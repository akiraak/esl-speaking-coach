import Foundation

/// 発話ごとの読み上げスタイル（キャラの voice とスタイル前置文）。
/// 2 キャラ台本では発話単位で ChatCharacter.speechStyle を渡す。
struct SpeechStyle: Sendable, Equatable {
    /// Gemini TTS の voice 名（Leda / Aoede 等）。OpenAI TTS は voice 体系が異なるため参照しない
    var voice: String
    /// 話し方を制御する自然文の前置指示
    var styleInstruction: String
}

/// TTS 1 リクエスト（1 文）分の利用量（料金記録用）。
struct TTSUsage: Sendable, Equatable {
    /// テキスト入力トークン（スタイル前置文 + 文）
    var inputTokens: Int?
    /// 音声出力トークン
    var outputTokens: Int?
    /// 受信 PCM から計算した音声の実時間（秒）。トークンが取れないときの推定用
    var audioSeconds: Double?
}

/// 文単位 TTS のストリーム要素。音声チャンクに加えて、終端で利用量を 1 回通知する。
enum TTSStreamChunk: Sendable {
    /// PCM16 24kHz mono LE の音声チャンク
    case pcm(Data)
    /// 利用量（ストリーム終端で 1 回。取れないプロバイダは流さない）
    case usage(TTSUsage)
}

/// 文単位 TTS の内部境界。VoiceSession 境界（CLAUDE.md）とは別に、
/// TTS 単体の差し替え（OpenAI ⇔ Gemini ⇔ 将来の Cartesia 等）をこの裏で行う。
protocol SentenceTTSClient: Sendable {
    /// 表示用のモデル名。
    var modelDescription: String { get }
    /// 1 文ぶんの音声チャンク列（+ 終端の利用量）をストリーミング取得する。
    func streamAudio(apiKey: String, text: String, style: SpeechStyle) -> AsyncThrowingStream<TTSStreamChunk, Error>
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
