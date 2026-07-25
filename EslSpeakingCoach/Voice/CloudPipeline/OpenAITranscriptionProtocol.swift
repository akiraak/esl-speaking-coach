import Foundation

/// OpenAI Realtime API の transcription セッション（案 A2 の STT）の設定。
/// 案 B と同じ GA 形式のイベント体系で、audio.input のみを構成する。
struct OpenAITranscriptionConfiguration: Sendable {
    /// STT モデル（voice-layer-spike.md Phase 3 の第一候補）
    var model = "gpt-4o-transcribe"
    /// 認識言語のヒント。会話は英語のみ（CLAUDE.md）なので en 固定
    var language = "en"
    /// 認識バイアス用ヒント。language=en 指定だけでは "Hello" 等の短い発話が
    /// 他言語（韓国語など）に誤判定される事象が実機で確認されたため併用する
    var prompt = """
        The speaker is a Japanese adult practicing English conversation. \
        The audio is always English.
        """
    /// サーバ VAD の発話終端とみなす無音時間。transcription セッションの既定 200ms は
    /// 考えながら話す ESL 学習者には短すぎ、発話が途中で切れやすいため長めにする
    var silenceDurationMs = 800

    var websocketURL: URL {
        URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!
    }
}

/// クライアント → サーバのイベント JSON を生成する。テストから直接検証できるよう純関数にする。
/// 音声チャンクの append は案 B の RealtimeClientEvent.inputAudioAppend を共用する。
enum OpenAITranscriptionClientEvent {
    static func sessionUpdate(configuration: OpenAITranscriptionConfiguration) throws -> Data {
        let payload: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24000],
                        "transcription": [
                            "model": configuration.model,
                            "language": configuration.language,
                            "prompt": configuration.prompt,
                        ],
                        "turn_detection": [
                            "type": "server_vad",
                            "silence_duration_ms": configuration.silenceDurationMs,
                        ],
                        "noise_reduction": ["type": "near_field"],
                    ],
                ],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }
}

/// STT ストリームが VoiceSession 側へ流すイベント。
enum STTStreamEvent: Sendable, Equatable {
    /// 接続・セッション設定が完了し、音声を送れる状態になった
    case ready
    /// サーバ VAD がユーザーの発話開始を検知した
    case speechStarted
    /// サーバ VAD が発話終端を検知した（この後 finalTranscript が届く）
    case speechStopped
    /// 認識途中のテキスト（セグメント内の累積）
    case partialTranscript(String)
    /// 1 セグメント分の確定テキスト
    case finalTranscript(String)
    /// セグメントの認識に失敗した（セッションは継続する）
    case transcriptFailed(String)
    case notice(String)
    /// 接続断・致命的エラー。呼び出し側でセッションを止める
    case connectionFailed(String)
}

/// ストリーミング STT の内部境界。VoiceSession 境界（CLAUDE.md）とは別に、
/// STT 単体の差し替え（gpt-4o-transcribe ⇔ Deepgram Flux 等の代替比較）をこの裏で行う。
@MainActor
protocol StreamingSpeechTranscriber: AnyObject {
    var events: AsyncStream<STTStreamEvent> { get }
    func connect()
    /// PCM16 24kHz mono の生バイト列を送る
    func sendAudio(_ chunk: Data)
    func stop()
}
