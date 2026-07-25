import Foundation

/// AI API 1 呼び出し分の利用量（プロバイダ非依存）。
/// 各クライアントがレスポンスの usage からこの形に詰め、UsageStore が記録する。
/// 取得は best effort（barge-in のキャンセル等で取れないことがある）。
struct AIUsageEvent: Sendable, Equatable {
    enum Provider: String, Sendable {
        case anthropic
        case openai
        case gemini
    }

    /// 課金 5 経路（docs/specs/ai-cost-map.md の #1〜#5）。
    enum Kind: String, Sendable, CaseIterable {
        case speechToText = "stt"
        case conversationTurn = "turn"
        case textToSpeech = "tts"
        case topicSuggestion = "topic"
        case sessionFeedback = "feedback"

        var label: String {
            switch self {
            case .speechToText: return "音声認識 (STT)"
            case .conversationTurn: return "会話ターン (LLM)"
            case .textToSpeech: return "読み上げ (TTS)"
            case .topicSuggestion: return "トピック生成"
            case .sessionFeedback: return "フィードバック生成"
            }
        }
    }

    var provider: Provider
    var model: String
    var kind: Kind
    /// テキスト入力トークン（STT はテキストヒント分）
    var inputTokens: Int?
    /// 出力トークン（TTS は音声出力トークン）
    var outputTokens: Int?
    /// プロンプトキャッシュ読み込みトークン（Claude）
    var cacheReadTokens: Int?
    /// プロンプトキャッシュ書き込みトークン（Claude）
    var cacheWriteTokens: Int?
    /// 音声入力トークン（STT）
    var audioInputTokens: Int?
    /// 音声の実時間（秒）。トークンが取れないときの料金推定フォールバック
    var audioSeconds: Double?

    init(
        provider: Provider,
        model: String,
        kind: Kind,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheWriteTokens: Int? = nil,
        audioInputTokens: Int? = nil,
        audioSeconds: Double? = nil
    ) {
        self.provider = provider
        self.model = model
        self.kind = kind
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.audioInputTokens = audioInputTokens
        self.audioSeconds = audioSeconds
    }
}
