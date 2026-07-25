import Foundation

/// OpenAI Realtime API（案 B）の接続設定。
struct RealtimeConfiguration: Sendable {
    /// コストの安い mini から検証する（voice-layer-spike.md Phase 1）
    var model = "gpt-realtime-2.1-mini"
    var voice = "marin"
    /// ユーザー発話の transcript 用モデル。評価フェーズで Claude に渡す transcript の品質に効く
    var transcriptionModel = "gpt-4o-transcribe"
    var instructions = CoachSystemPrompt.text

    var websocketURL: URL {
        URL(string: "wss://api.openai.com/v1/realtime?model=\(model)")!
    }
}

/// クライアント → サーバのイベント JSON を生成する。テストから直接検証できるよう純関数にする。
/// GA 形式（session.audio.input / output のネスト構造）。model は URL クエリで指定するため含めない。
enum RealtimeClientEvent {
    static func sessionUpdate(configuration: RealtimeConfiguration) throws -> Data {
        let payload: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "output_modalities": ["audio"],
                "instructions": configuration.instructions,
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24000],
                        "turn_detection": ["type": "server_vad"],
                        "transcription": ["model": configuration.transcriptionModel],
                    ],
                    "output": [
                        "format": ["type": "audio/pcm", "rate": 24000],
                        "voice": configuration.voice,
                    ],
                ],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    static func inputAudioAppend(base64Audio: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": "input_audio_buffer.append",
            "audio": base64Audio,
        ])
    }

    static func userTextItem(_ text: String) throws -> Data {
        let payload: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": text]],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    static func responseCreate() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": "response.create"])
    }

    static func responseCancel() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": "response.cancel"])
    }
}

/// サーバ → クライアントのイベント。会話ロジックが必要とする最小のみ拾う。
enum RealtimeServerEvent: Sendable, Equatable {
    case sessionCreated
    case sessionUpdated
    case speechStarted
    case speechStopped
    case userTranscriptDelta(String)
    case userTranscriptCompleted(String)
    /// ユーザー発話セグメントの認識に失敗した（セッション自体は継続する）
    case userTranscriptFailed(String)
    case responseCreated
    /// base64 デコード済みの PCM16 24kHz mono チャンク
    case assistantAudioDelta(Data)
    case assistantTranscriptDelta(String)
    case assistantTranscriptDone(String)
    case responseDone
    /// ignorable = 実害のない既知のエラー（サーバ側の自動 interrupt と response.cancel が競合した等）
    case serverError(message: String, ignorable: Bool)
    case ignored(type: String)

    static func parse(_ text: String) -> RealtimeServerEvent {
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
            return .userTranscriptCompleted(object["transcript"] as? String ?? "")
        case "conversation.item.input_audio_transcription.failed":
            let error = object["error"] as? [String: Any]
            return .userTranscriptFailed(error?["message"] as? String ?? "transcription failed")
        case "response.created":
            return .responseCreated
        case "response.output_audio.delta":
            guard let base64 = object["delta"] as? String,
                  let audio = Data(base64Encoded: base64)
            else { return .ignored(type: type) }
            return .assistantAudioDelta(audio)
        case "response.output_audio_transcript.delta":
            return .assistantTranscriptDelta(object["delta"] as? String ?? "")
        case "response.output_audio_transcript.done":
            return .assistantTranscriptDone(object["transcript"] as? String ?? "")
        case "response.done":
            return .responseDone
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
