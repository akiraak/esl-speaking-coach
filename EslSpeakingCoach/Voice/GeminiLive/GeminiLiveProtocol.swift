import Foundation

/// Gemini Live API（案 C）の接続設定。
struct GeminiLiveConfiguration: Sendable {
    /// 2026-07 時点の現行 Live モデル（voice-layer-spike.md Phase 2）
    var model = "gemini-3.1-flash-live-preview"
    var voice = "Aoede"
    var instructions = CoachSystemPrompt.text

    /// マイク入力は 16kHz PCM16 mono little-endian（Live API の仕様）。出力は 24kHz。
    static let inputSampleRate = 16000
    static let outputSampleRate = 24000

    /// Live API の WebSocket 認証は URL クエリの key で行う（公式ドキュメントの方式）。
    func websocketURL(apiKey: String) -> URL? {
        guard let encoded = apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return nil }
        return URL(string: "wss://generativelanguage.googleapis.com/ws/"
            + "google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
            + "?key=\(encoded)")
    }
}

/// クライアント → サーバのメッセージ JSON を生成する。テストから直接検証できるよう純関数にする。
/// 接続後の最初のメッセージは必ず setup で、setupComplete を受けてから音声を流し始める。
enum GeminiLiveClientEvent {
    static func setup(configuration: GeminiLiveConfiguration) throws -> Data {
        let payload: [String: Any] = [
            "setup": [
                "model": "models/\(configuration.model)",
                "generationConfig": [
                    "responseModalities": ["AUDIO"],
                    "speechConfig": [
                        "voiceConfig": [
                            "prebuiltVoiceConfig": ["voiceName": configuration.voice]
                        ]
                    ],
                ],
                "systemInstruction": [
                    "parts": [["text": configuration.instructions]]
                ],
                // 評価フェーズで Claude に渡す transcript を得るため入出力とも文字起こしを有効化
                "inputAudioTranscription": [:],
                "outputAudioTranscription": [:],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    static func audioChunk(base64Audio: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "realtimeInput": [
                "audio": [
                    "data": base64Audio,
                    "mimeType": "audio/pcm;rate=\(GeminiLiveConfiguration.inputSampleRate)",
                ],
            ],
        ])
    }

    static func userTextTurn(_ text: String) throws -> Data {
        let payload: [String: Any] = [
            "clientContent": [
                "turns": [
                    ["role": "user", "parts": [["text": text]]]
                ],
                "turnComplete": true,
            ],
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }
}

/// サーバ → クライアントのメッセージ。トップレベルは union だが、serverContent の中には
/// 複数のサブイベント（音声デルタ + transcript + turnComplete 等）が同居し得るため、
/// parse は配列で返す（配列の順に処理すれば安全な順序にしてある: transcript → 音声 → interrupted → 完了）。
enum GeminiLiveServerEvent: Sendable, Equatable {
    case setupComplete
    /// サーバ VAD がユーザーの発話開始を検知して応答生成を打ち切った（barge-in）
    case interrupted
    /// モデルの応答生成が終わった（音声の再生完了より先に来る）
    case generationComplete
    /// ターン全体の終了
    case turnComplete
    /// ユーザー発話の文字起こし断片（累積はクライアント側で行う）
    case userTranscriptDelta(String)
    /// AI 音声の文字起こし断片
    case assistantTranscriptDelta(String)
    /// base64 デコード済みの PCM16 24kHz mono チャンク
    case assistantAudioDelta(Data)
    /// 接続の終了予告（timeLeft は proto Duration の文字列表現）
    case goAway(timeLeft: String)
    case ignored(field: String)

    static func parse(_ text: String) -> [GeminiLiveServerEvent] {
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return [.ignored(field: "(unparsable)")]
        }

        if object["setupComplete"] != nil {
            return [.setupComplete]
        }
        if let goAway = object["goAway"] as? [String: Any] {
            return [.goAway(timeLeft: goAway["timeLeft"].map { "\($0)" } ?? "?")]
        }
        if let serverContent = object["serverContent"] as? [String: Any] {
            var events: [GeminiLiveServerEvent] = []
            if let transcription = serverContent["inputTranscription"] as? [String: Any],
               let fragment = transcription["text"] as? String, !fragment.isEmpty {
                events.append(.userTranscriptDelta(fragment))
            }
            if let transcription = serverContent["outputTranscription"] as? [String: Any],
               let fragment = transcription["text"] as? String, !fragment.isEmpty {
                events.append(.assistantTranscriptDelta(fragment))
            }
            if let modelTurn = serverContent["modelTurn"] as? [String: Any],
               let parts = modelTurn["parts"] as? [[String: Any]] {
                for part in parts {
                    if let inline = part["inlineData"] as? [String: Any],
                       let base64 = inline["data"] as? String,
                       let audio = Data(base64Encoded: base64) {
                        events.append(.assistantAudioDelta(audio))
                    }
                }
            }
            if serverContent["interrupted"] as? Bool == true {
                events.append(.interrupted)
            }
            if serverContent["generationComplete"] as? Bool == true {
                events.append(.generationComplete)
            }
            if serverContent["turnComplete"] as? Bool == true {
                events.append(.turnComplete)
            }
            return events.isEmpty ? [.ignored(field: "serverContent")] : events
        }
        return [.ignored(field: object.keys.sorted().joined(separator: ","))]
    }
}
