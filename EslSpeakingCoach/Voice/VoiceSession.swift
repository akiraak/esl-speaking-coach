import Foundation

/// 音声会話セッションの状態。
enum VoiceSessionState: String, Sendable {
    /// 未開始 / 停止済み
    case idle
    /// 起動処理中（権限・STT モデル準備・マイク起動）
    case preparing
    /// ユーザーの発話を聞き取り中
    case listening
    /// Claude の応答待ち（発話は未開始）
    case thinking
    /// AI の音声を再生中
    case speaking
}

/// セッションから UI へ流すイベント。
enum VoiceSessionEvent: Sendable {
    case stateChanged(VoiceSessionState)
    /// 聞き取り中の暫定テキスト（volatile + finalized の現在形）
    case userPartialTranscript(String)
    /// 発話終端が確定し、user ターンとして履歴に積んだ
    case userTurnCommitted(String)
    /// Claude のストリーミング応答の断片
    case assistantTextDelta(String)
    /// assistant ターンの全文が確定した
    case assistantTurnCompleted(String)
    /// 1 ターン分のレイテンシ実測値
    case turnMetrics(TurnMetrics)
    /// マイク入力の RMS レベル（barge-in しきい値チューニング用）
    case micLevel(Float)
    case info(String)
    case failure(String)
}

/// 1 ターンのレイテンシ実測値（ミリ秒）。voice-layer-spike.md の評価軸 1 に対応する。
struct TurnMetrics: Sendable, Equatable {
    /// 発話終端（最後の認識更新）→ 無音判定（silenceWindow ぶんの固定待ち）
    var endpointWaitMs: Double?
    /// 無音判定 → STT の確定テキスト取得
    var sttFinalizeMs: Double?
    /// リクエスト送信 → 最初のテキストデルタ（Claude の TTFT）
    var ttftMs: Double?
    /// 最初のデルタ → 最初の文の確定
    var firstSentenceMs: Double?
    /// 最初の文の確定 → 読み上げ音声の再生開始
    var speakStartMs: Double?
    /// 無音判定 → 再生開始（パイプライン合計）
    var pipelineTotalMs: Double?
    /// 発話終端 → 再生開始(体感レイテンシ。endpointWait を含む)
    var perceivedTotalMs: Double?
}

/// 音声入出力の抽象境界。UI と会話ロジックはこのプロトコルにのみ依存する（CLAUDE.md の設計制約）。
/// 案 A（ターン制パイプライン）でも案 B/C（speech-to-speech）でも同じ形で差し替えられるよう、
/// 発話取得・読み上げ・割り込み検知はすべてこの裏に隠す。
@MainActor
protocol VoiceSession: AnyObject {
    var events: AsyncStream<VoiceSessionEvent> { get }
    func start() async
    func stop()
    #if DEBUG
    /// マイク・STT を経由せず user ターンを投入する（シミュレータでマイクが使えないときの検証用）。
    func submitTypedUserTurn(_ text: String)
    #endif
}

/// 検証中の音声レイヤ実装の選択肢（voice-layer-spike.md の比較対象）。
enum VoiceEngine: String, CaseIterable, Identifiable, Sendable {
    /// ターン制パイプライン + Claude（旧案 A → 案 A2）
    case turnPipeline = "turn"
    /// 案 B: OpenAI Realtime speech-to-speech
    case openaiRealtime = "realtime"
    /// 案 C: Gemini Live speech-to-speech
    case geminiLive = "gemini"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .turnPipeline: return "ターン制+Claude"
        case .openaiRealtime: return "OpenAI Realtime"
        case .geminiLive: return "Gemini Live"
        }
    }
}
