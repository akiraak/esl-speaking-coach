import Foundation

/// 音声会話セッションの状態。
enum VoiceSessionState: String, Sendable {
    /// 未開始 / 停止済み
    case idle
    /// 起動処理中（権限・接続・マイク起動）
    case preparing
    /// ユーザーの発話を聞き取り中
    case listening
    /// Claude の応答待ち（発話は未開始）
    case thinking
    /// AI の音声を再生中
    case speaking
    /// STT 接続が切れて再接続を試みている（会話履歴は保持）
    case reconnecting
    /// オーディオ割り込み（電話等）・バックグラウンド遷移で一時停止中（会話履歴は保持）
    case suspended
}

/// セッションから UI へ流すイベント。
enum VoiceSessionEvent: Sendable {
    case stateChanged(VoiceSessionState)
    /// 聞き取り中の暫定テキスト（volatile + finalized の現在形）
    case userPartialTranscript(String)
    /// 発話終端が確定し、user ターンとして履歴に積んだ
    case userTurnCommitted(String)
    /// 発話（1 キャラの 1 吹き出し）の読み上げが実際に始まった。text はその時点までの確定分
    case assistantUtteranceBegan(id: UUID, speaker: ChatCharacter, text: String)
    /// 読み上げ開始済みの発話のテキストがストリーミングで伸びた
    case assistantUtteranceUpdated(id: UUID, text: String)
    /// 学習者の goodbye（制御行 [end]）を検知した。closing の読み上げ完了後に通知する
    case sessionEndDetected
    /// AI API 1 呼び出し分の利用量（STT 1 セグメント / Claude 1 ターン / TTS 1 文。料金記録用）
    case apiUsage(AIUsageEvent)
    /// 1 ターン分のレイテンシ実測値
    case turnMetrics(TurnMetrics)
    /// マイク入力の RMS レベル（音声モードの波形表示用）
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
/// 発話取得・読み上げ・割り込み検知はすべてこの裏に隠す。
@MainActor
protocol VoiceSession: AnyObject {
    var events: AsyncStream<VoiceSessionEvent> { get }
    func start() async
    func stop()
    /// テキストモードの user ターン投入（マイク・STT を経由しない。AI は音声で返す）。
    /// 読み上げ / 生成中の送信は barge-in と同じ扱いになる。
    func submitTypedUserTurn(_ text: String)
    /// 音声入力（STT 接続 + マイク）の有効 / 無効。読み上げ（TTS）には影響しない。
    /// 入力バーのテキスト⇔音声モード切替と、音声モードの一時停止（⏸）から呼ぶ。
    func setVoiceInputEnabled(_ enabled: Bool)
}
