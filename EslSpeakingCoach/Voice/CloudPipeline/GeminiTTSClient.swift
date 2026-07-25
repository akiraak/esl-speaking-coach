import Foundation

/// Gemini TTS（採用 TTS）の設定。voice / スタイル前置文は発話ごとに SpeechStyle で受け取る
/// （2 キャラの voice 切替。ChatCharacter.speechStyle が渡ってくる）。
struct GeminiTTSConfiguration: Sendable {
    /// 2026-07 時点の現行 TTS モデル（models エンドポイントで確認済み）
    var model = "gemini-3.1-flash-tts-preview"

    /// 認証は URL クエリの key。
    func endpoint(apiKey: String) -> URL {
        URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse&key=\(apiKey)")!
    }
}

enum GeminiTTSError: Error, LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Gemini TTS サーバーから不正な応答が返りました"
        case .httpError(let statusCode, let body):
            return "Gemini TTS HTTP \(statusCode): \(body.prefix(300))"
        case .apiError(let message):
            return "Gemini TTS API エラー: \(message)"
        }
    }
}

/// streamGenerateContent（SSE）で音声を取得する。出力は audio/l16 rate=24000 mono で、
/// 実測でリトルエンディアン PCM16 と確認済み（StreamingAudioPlayer にそのまま流せる）。
struct GeminiTTSClient: SentenceTTSClient {
    var configuration = GeminiTTSConfiguration()

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        return URLSession(configuration: configuration)
    }()

    var modelDescription: String {
        configuration.model
    }

    /// リクエストボディを生成する。テストから直接検証できるよう static にしてある。
    /// Gemini TTS は独立した instructions フィールドが無く、テキスト先頭の自然文指示で話し方を制御する。
    static func makeRequestBody(
        configuration: GeminiTTSConfiguration, text: String, style: SpeechStyle
    ) throws -> Data {
        let payload: [String: Any] = [
            "contents": [
                ["parts": [["text": style.styleInstruction + "\n" + text]]]
            ],
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": [
                    "voiceConfig": [
                        "prebuiltVoiceConfig": ["voiceName": style.voice]
                    ]
                ],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    func streamPCM(apiKey: String, text: String, style: SpeechStyle) -> AsyncThrowingStream<Data, Error> {
        let configuration = configuration
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: configuration.endpoint(apiKey: apiKey))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try Self.makeRequestBody(
                        configuration: configuration, text: text, style: style)

                    let (bytes, response) = try await Self.session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw GeminiTTSError.invalidResponse
                    }
                    guard http.statusCode == 200 else {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                            if body.count > 2000 { break }
                        }
                        throw GeminiTTSError.httpError(statusCode: http.statusCode, body: body)
                    }

                    // サーバのチャンクは 40ms 刻みと細かいため、再生スケジューリング単位へまとめ直す
                    var assembler = PCMChunkAssembler()
                    for try await line in bytes.lines {
                        if let pcm = try GeminiTTSSSE.parse(line: line),
                           let chunk = assembler.append(contentsOf: pcm) {
                            continuation.yield(chunk)
                        }
                    }
                    if let rest = assembler.flush() {
                        continuation.yield(rest)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// streamGenerateContent の SSE 1 行から PCM チャンクを取り出す。
enum GeminiTTSSSE {
    /// `data: {...}` 以外の行（空行等）と音声を含まないチャンクは nil を返す。
    /// エラーイベントは throw する。
    static func parse(line: String) throws -> Data? {
        guard line.hasPrefix("data:") else { return nil }
        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }

        if let message = payload.error?.message {
            throw GeminiTTSError.apiError(message)
        }
        // 1 チャンクに複数 part が入り得るため連結する
        var pcm = Data()
        for candidate in payload.candidates ?? [] {
            for part in candidate.content?.parts ?? [] {
                if let base64 = part.inlineData?.data, let audio = Data(base64Encoded: base64) {
                    pcm.append(audio)
                }
            }
        }
        return pcm.isEmpty ? nil : pcm
    }

    private struct Payload: Decodable {
        let candidates: [Candidate]?
        let error: APIError?

        struct Candidate: Decodable {
            let content: Content?
        }

        struct Content: Decodable {
            let parts: [Part]?
        }

        struct Part: Decodable {
            let inlineData: InlineData?
        }

        struct InlineData: Decodable {
            let mimeType: String?
            let data: String?
        }

        struct APIError: Decodable {
            let message: String?
        }
    }
}
