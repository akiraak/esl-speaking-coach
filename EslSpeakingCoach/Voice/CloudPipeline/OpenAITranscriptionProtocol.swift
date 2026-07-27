import Foundation

/// OpenAI Realtime API の transcription セッション（STT）の設定。
/// GA 形式のイベント体系で、audio.input のみを構成する。
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
    /// サーバ VAD の発話終端とみなす無音時間。transcription セッションの既定 500ms は
    /// 考えながら話す ESL 学習者には短すぎ、発話が途中で切れやすいため長めにする
    var silenceDurationMs = 800
    /// サーバ VAD が発話とみなす音声確率のしきい値（0.0〜1.0）。既定 0.5 のままだと
    /// 咳・物音・部屋の向こうのテレビでもセグメントが切り出され、雑音が書き起こされて
    /// 会話に入ってしまう。公式ガイドが「騒がしい環境では上げる」と明記しているため上げる
    /// （docs/plans/noise-input-rejection.md Phase 1。実機で 0.55〜0.7 を調整する）
    var vadThreshold = 0.6
    /// 発話開始と判定した時点より前に遡って含める音声。既定値どおりだが、語頭の欠けは
    /// 体感の劣化が大きいので既定変更に巻き込まれないよう明示指定して固定する
    var prefixPaddingMs = 300

    var websocketURL: URL {
        URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!
    }
}

/// STT の幻覚（prompt leakage）対策。gpt-4o-transcribe は Hum・咳など実質非発話の
/// セグメントで、認識バイアス用 prompt をそのまま書き起こしとして出力することがある
/// （調査記録: docs/plans/stt-prompt-echo-hallucination.md）。
enum STTHallucinationFilter {
    /// 誤爆防止の最小長（正規化後）。prompt 冒頭と偶然一致しうる短い正当発話は通す
    private static let minimumEchoLength = 12

    /// transcript が prompt のエコー（全体・先頭の切れ端・繰り返し）とみなせるなら true。
    /// leakage は prompt の先頭から始まるため、途中だけの一致（"English conversation" 等の
    /// 正当な発話）はエコー扱いしない
    static func isPromptEcho(transcript: String, prompt: String) -> Bool {
        let echo = normalize(transcript)
        let source = normalize(prompt)
        guard !source.isEmpty, echo.count >= minimumEchoLength else { return false }

        // prompt 丸ごとを先頭から取り除けるだけ取り除く（2 回繰り返しエコー等）
        var remainder = Substring(echo)
        var fullMatches = 0
        while remainder.hasPrefix(source) {
            remainder = remainder.dropFirst(source.count)
            fullMatches += 1
        }
        if fullMatches > 0 {
            // 残りが空 or prompt の先頭部分なら「prompt の繰り返し + 切れ端」のエコー
            return remainder.isEmpty || source.hasPrefix(remainder)
        }
        // 丸ごとは含まない: prompt の先頭部分だけの（末尾が切れた）エコー
        return source.hasPrefix(echo)
    }

    /// 大文字小文字・句読点・空白の揺れを無視して比較するため英数字のみに正規化する
    private static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }
}

/// クライアント → サーバのイベント JSON を生成する。テストから直接検証できるよう純関数にする。
enum OpenAITranscriptionClientEvent {
    static func inputAudioAppend(base64Audio: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": "input_audio_buffer.append",
            "audio": base64Audio,
        ])
    }

    /// `Double` をそのまま `JSONSerialization` に渡すと 0.6 が `0.59999999999999998` と
    /// 17 桁で書かれ、OpenAI に "max decimal places exceeded"（上限 16 桁）で弾かれる。
    /// 小数 2 桁へ丸めた `NSDecimalNumber` にすると `0.6` と書かれる（閾値の刻みは 0.01 で十分）
    static func jsonNumber(_ value: Double) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.2f", value))
    }

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
                            "threshold": jsonNumber(configuration.vadThreshold),
                            "prefix_padding_ms": configuration.prefixPaddingMs,
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

/// STT 1 セグメント分の利用量（transcription.completed の usage。料金記録用）。
/// gpt-4o-transcribe はトークン型（audio/text 入力 + 出力）、whisper 系は秒数型で届く。
struct STTSegmentUsage: Sendable, Equatable {
    var audioInputTokens: Int?
    var textInputTokens: Int?
    var outputTokens: Int?
    var audioSeconds: Double?

    /// completed イベントの usage オブジェクトからパースする（形式不明なら nil）。
    static func parse(_ object: [String: Any]?) -> STTSegmentUsage? {
        guard let object, let type = object["type"] as? String else { return nil }
        switch type {
        case "tokens":
            let details = object["input_token_details"] as? [String: Any]
            return STTSegmentUsage(
                audioInputTokens: details?["audio_tokens"] as? Int,
                textInputTokens: details?["text_tokens"] as? Int,
                outputTokens: object["output_tokens"] as? Int)
        case "duration":
            guard let seconds = object["seconds"] as? Double else { return nil }
            return STTSegmentUsage(audioSeconds: seconds)
        default:
            return nil
        }
    }
}

/// サーバ → クライアントのイベント。transcription セッションが必要とする最小のみ拾う。
enum OpenAITranscriptionServerEvent: Sendable, Equatable {
    case sessionCreated
    case sessionUpdated
    case speechStarted
    case speechStopped
    case userTranscriptDelta(String)
    case userTranscriptCompleted(String, usage: STTSegmentUsage?)
    /// ユーザー発話セグメントの認識に失敗した（セッション自体は継続する）
    case userTranscriptFailed(String)
    /// ignorable = 実害のない既知のエラー
    case serverError(message: String, ignorable: Bool)
    case ignored(type: String)

    static func parse(_ text: String) -> OpenAITranscriptionServerEvent {
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String
        else {
            return .ignored(type: "(unparsable)")
        }

        switch type {
        case "session.created":
            return .sessionCreated
        case "session.updated":
            return .sessionUpdated
        case "input_audio_buffer.speech_started":
            return .speechStarted
        case "input_audio_buffer.speech_stopped":
            return .speechStopped
        case "conversation.item.input_audio_transcription.delta":
            return .userTranscriptDelta(object["delta"] as? String ?? "")
        case "conversation.item.input_audio_transcription.completed":
            return .userTranscriptCompleted(
                object["transcript"] as? String ?? "",
                usage: STTSegmentUsage.parse(object["usage"] as? [String: Any]))
        case "conversation.item.input_audio_transcription.failed":
            let error = object["error"] as? [String: Any]
            return .userTranscriptFailed(error?["message"] as? String ?? "transcription failed")
        case "error":
            let error = object["error"] as? [String: Any]
            let code = error?["code"] as? String ?? ""
            let message = error?["message"] as? String ?? "unknown error"
            let ignorable = code == "response_cancel_not_active"
                || message.lowercased().contains("no active response")
            return .serverError(message: message, ignorable: ignorable)
        default:
            return .ignored(type: type)
        }
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
    /// 1 セグメント分の利用量（finalTranscript の直前に届く。料金記録用）
    case segmentUsage(STTSegmentUsage)
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
