import Foundation

/// Alibaba Model Studio の Qwen3-TTS リアルタイム合成（WebSocket）の設定。
/// 検証用の切替経路（docs/plans/alibaba-voice-models.md）。既定の TTS は Gemini のまま。
struct QwenTTSConfiguration: Sendable {
    var model = "qwen3-tts-flash-realtime"
    /// SpeechStyle.voice は Gemini の voice 名（Leda / Aoede）で届くため、ここで
    /// Qwen の voice 名へ写像する（OpenAITTSClient が固定 coral で読むのと同じ扱い）。
    /// 割り当ては実聴で調整する（Chobi=Leda / Naruko=Aoede）
    var voiceMap: [String: String] = ["Leda": "Cherry", "Aoede": "Serena"]
    var defaultVoice = "Cherry"

    var websocketURL: URL {
        URL(string: "wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime?model=\(model)")!
    }

    func voice(for style: SpeechStyle) -> String {
        voiceMap[style.voice] ?? defaultVoice
    }
}

enum QwenTTSError: Error, LocalizedError {
    /// 接続が使えない状態だった（張り直して 1 回だけ再試行する）
    case connectionLost(String)
    case serverError(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .connectionLost(let detail): return "Qwen TTS 接続が切れました: \(detail)"
        case .serverError(let message): return "Qwen TTS API エラー: \(message)"
        case .timeout(let phase): return "Qwen TTS 応答待ちがタイムアウトしました（\(phase)）"
        }
    }
}

/// Qwen3-TTS リアルタイム API（WebSocket・commit モード）で 1 文ずつ合成する。
/// 出力は 24kHz PCM16 mono LE（現行 Gemini TTS と同一。StreamingAudioPlayer にそのまま流せる）。
///
/// WebSocket は voice ごとに張りっぱなしにして文単位の commit を繰り返す
/// （voice は接続の最初の session.update でしか設定できないため、2 キャラ = 2 接続。
/// 接続を張り直すと文単位 TTFB 約 0.4 秒に加えて接続 0.8 秒がかかるので使い回す）。
/// アイドルでサーバに切られていた場合は張り直して 1 回だけ再試行する。
/// barge-in（ストリーム途中キャンセル）した接続は応答が残留しているため破棄する。
final class QwenTTSClient: SentenceTTSClient {
    let configuration: QwenTTSConfiguration
    private let pool: QwenTTSConnectionPool

    init(configuration: QwenTTSConfiguration = QwenTTSConfiguration()) {
        self.configuration = configuration
        self.pool = QwenTTSConnectionPool(configuration: configuration)
    }

    var modelDescription: String {
        configuration.model
    }

    func streamAudio(apiKey: String, text: String, style: SpeechStyle) -> AsyncThrowingStream<TTSStreamChunk, Error> {
        let configuration = configuration
        let pool = pool
        return AsyncThrowingStream { continuation in
            let task = Task {
                let voice = configuration.voice(for: style)
                do {
                    do {
                        try await pool.synthesize(voice: voice, apiKey: apiKey, text: text) {
                            continuation.yield($0)
                        }
                    } catch let error as QwenTTSError {
                        // アイドル切断・タイムアウトは接続を捨てて 1 回だけ張り直す
                        guard !Task.isCancelled else { throw CancellationError() }
                        await pool.discard(voice: voice)
                        if case .serverError = error { throw error }
                        try await pool.synthesize(voice: voice, apiKey: apiKey, text: text) {
                            continuation.yield($0)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    // barge-in。取得途中の接続は応答が残留しているので捨てる
                    await pool.discard(voice: voice)
                    continuation.finish(throwing: CancellationError())
                } catch {
                    await pool.discard(voice: voice)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// voice ごとの接続の置き場。synthesize は接続単位で直列（ターン制 + 文単位の逐次取得なので
/// 同時に 2 文を投げることはないが、actor 隔離で保険をかける）。
private actor QwenTTSConnectionPool {
    private let configuration: QwenTTSConfiguration
    private var connections: [String: QwenTTSConnection] = [:]

    init(configuration: QwenTTSConfiguration) {
        self.configuration = configuration
    }

    func synthesize(
        voice: String, apiKey: String, text: String,
        onChunk: @escaping @Sendable (TTSStreamChunk) -> Void
    ) async throws {
        let connection: QwenTTSConnection
        if let existing = connections[voice] {
            connection = existing
        } else {
            connection = QwenTTSConnection(
                url: configuration.websocketURL, apiKey: apiKey, voice: voice)
            connections[voice] = connection
            try await connection.prepare()
        }
        try await connection.synthesize(text: text, onChunk: onChunk)
    }

    func discard(voice: String) async {
        guard let connection = connections.removeValue(forKey: voice) else { return }
        await connection.close()
    }
}

/// 1 本の WebSocket 接続（voice 固定）。receive は synthesize / prepare の中で直列に回す
/// （文間はイベントが来ない前提。沈黙・切断はタイムアウトで検知して呼び出し側が張り直す）。
private actor QwenTTSConnection {
    private let webSocket: URLSessionWebSocketTask
    private let voice: String
    private var isReady = false

    private static let urlSession = URLSession(configuration: .default)

    init(url: URL, apiKey: String, voice: String) {
        var request = URLRequest(url: url)
        request.setValue("bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        self.webSocket = Self.urlSession.webSocketTask(with: request)
        self.voice = voice
        webSocket.resume()
    }

    /// session.created を待って voice / 出力形式を設定し、session.updated まで確認する。
    func prepare() async throws {
        try await waitForEvent(ofType: "session.created", timeoutSeconds: 10, phase: "接続")
        try await send([
            "type": "session.update",
            "session": [
                "voice": voice,
                "mode": "commit",
                "response_format": "pcm",
                "sample_rate": 24000,
                "language_type": "English",
            ],
        ])
        try await waitForEvent(ofType: "session.updated", timeoutSeconds: 10, phase: "セッション設定")
        isReady = true
    }

    /// 1 文を append + commit し、response.done まで音声チャンクを流す。
    func synthesize(
        text: String, onChunk: @escaping @Sendable (TTSStreamChunk) -> Void
    ) async throws {
        guard isReady else { throw QwenTTSError.connectionLost("セッション未設定") }
        try await send(["type": "input_text_buffer.append", "text": text])
        try await send(["type": "input_text_buffer.commit"])

        // サーバのチャンクは細かいので再生スケジューリング単位へまとめ直す（他クライアントと同じ）
        var assembler = PCMChunkAssembler()
        var totalPCMBytes = 0
        var billedCharacters: Int?
        var audioOutputTokens: Int?

        while true {
            try Task.checkCancellation()
            let object = try await receive(timeoutSeconds: 30, phase: "音声チャンク")
            switch object["type"] as? String {
            case "response.audio.delta":
                if let base64 = object["delta"] as? String,
                   let pcm = Data(base64Encoded: base64)
                {
                    totalPCMBytes += pcm.count
                    if let chunk = assembler.append(contentsOf: pcm) {
                        onChunk(.pcm(chunk))
                    }
                }
            case "response.done":
                // usage.characters が課金単位（$/1 万字）。TTSUsage.inputTokens に文字数を
                // 入れて運ぶ（AIPricing の alibaba 分岐がそのまま文字数として読む）
                if let response = object["response"] as? [String: Any],
                   let usage = response["usage"] as? [String: Any]
                {
                    billedCharacters = usage["characters"] as? Int
                    let outputDetails = usage["output_tokens_details"] as? [String: Any]
                    audioOutputTokens = outputDetails?["audio_tokens"] as? Int
                }
                if let rest = assembler.flush() {
                    onChunk(.pcm(rest))
                }
                if totalPCMBytes > 0 || billedCharacters != nil {
                    onChunk(.usage(TTSUsage(
                        inputTokens: billedCharacters,
                        outputTokens: audioOutputTokens,
                        // 24kHz PCM16 mono = 48,000 bytes/秒
                        audioSeconds: Double(totalPCMBytes) / 48_000)))
                }
                return
            case "error":
                let error = object["error"] as? [String: Any]
                throw QwenTTSError.serverError(error?["message"] as? String ?? "unknown error")
            default:
                break
            }
        }
    }

    func close() {
        webSocket.cancel(with: .goingAway, reason: nil)
    }

    private func send(_ object: [String: Any]) async throws {
        var payload = object
        payload["event_id"] = UUID().uuidString
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw QwenTTSError.connectionLost("ペイロードの生成に失敗")
        }
        do {
            try await webSocket.send(.string(text))
        } catch {
            throw QwenTTSError.connectionLost(error.localizedDescription)
        }
    }

    private func waitForEvent(
        ofType type: String, timeoutSeconds: Double, phase: String
    ) async throws {
        while true {
            let object = try await receive(timeoutSeconds: timeoutSeconds, phase: phase)
            if object["type"] as? String == type { return }
            if object["type"] as? String == "error" {
                let error = object["error"] as? [String: Any]
                throw QwenTTSError.serverError(error?["message"] as? String ?? "unknown error")
            }
        }
    }

    /// 1 イベント受信。タイムアウトしたら接続ごと壊して connectionLost にする
    /// （receive はキャンセルで中断できないため、socket の cancel で強制的に落とす）。
    private func receive(timeoutSeconds: Double, phase: String) async throws -> [String: Any] {
        let webSocket = webSocket
        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            guard !Task.isCancelled else { return }
            webSocket.cancel(with: .goingAway, reason: nil)
        }
        defer { timeoutTask.cancel() }
        let start = ContinuousClock.now
        do {
            let message = try await webSocket.receive()
            let text: String?
            switch message {
            case .string(let string): text = string
            case .data(let data): text = String(data: data, encoding: .utf8)
            @unknown default: text = nil
            }
            guard let text,
                  let object = (try? JSONSerialization.jsonObject(
                    with: Data(text.utf8))) as? [String: Any]
            else {
                return [:]
            }
            return object
        } catch {
            // receive はキャンセルで中断できないため、タイムアウトかどうかは経過時間で判別する
            if ContinuousClock.now - start >= .seconds(timeoutSeconds) {
                throw QwenTTSError.timeout(phase)
            }
            throw QwenTTSError.connectionLost(error.localizedDescription)
        }
    }
}
