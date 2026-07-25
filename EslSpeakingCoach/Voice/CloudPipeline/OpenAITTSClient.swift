import Foundation

/// gpt-4o-mini-tts（案 A2 の TTS）の設定。
struct OpenAITTSConfiguration: Sendable {
    var model = "gpt-4o-mini-tts"
    var voice = "coral"
    /// 話し方の指示（gpt-4o-mini-tts は instructions で話速・トーンを制御できる。ESL 適性の根拠）
    var instructions = """
        You are the voice of a warm, friendly English conversation coach talking with an adult \
        ESL learner. Speak clearly at a natural, slightly unhurried pace. Sound encouraging and \
        genuinely curious.
        """
    var endpoint = URL(string: "https://api.openai.com/v1/audio/speech")!
}

enum OpenAITTSError: Error, LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "TTS サーバーから不正な応答が返りました"
        case .httpError(let statusCode, let body):
            return "TTS HTTP \(statusCode): \(body.prefix(300))"
        }
    }
}

/// /v1/audio/speech を response_format=pcm で叩き、24kHz PCM16 mono LE のチャンクを
/// ストリーミングで取り出す。文単位の 1 リクエスト（ターン制なので WebSocket は不要）。
struct OpenAITTSClient: SentenceTTSClient {
    var configuration = OpenAITTSConfiguration()

    var voiceDescription: String {
        "\(configuration.model) (\(configuration.voice))"
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        return URLSession(configuration: configuration)
    }()

    /// リクエストボディを生成する。テストから直接検証できるよう static にしてある。
    static func makeRequestBody(configuration: OpenAITTSConfiguration, text: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "model": configuration.model,
            "voice": configuration.voice,
            "input": text,
            "instructions": configuration.instructions,
            "response_format": "pcm",
        ])
    }

    /// 1 文ぶんの音声を PCM16 24kHz mono LE のチャンク列としてストリーミング取得する。
    func streamPCM(apiKey: String, text: String) -> AsyncThrowingStream<Data, Error> {
        let configuration = configuration
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: configuration.endpoint)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try Self.makeRequestBody(configuration: configuration, text: text)

                    let (bytes, response) = try await Self.session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw OpenAITTSError.invalidResponse
                    }
                    guard http.statusCode == 200 else {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                            if body.count > 2000 { break }
                        }
                        throw OpenAITTSError.httpError(statusCode: http.statusCode, body: body)
                    }

                    var assembler = PCMChunkAssembler()
                    for try await byte in bytes {
                        if let chunk = assembler.append(byte) {
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

/// 受信バイト列を PCM16 の偶数バイト境界かつ最小チャンクサイズで区切る
/// （HTTP のチャンクはサンプル境界と無関係に切れるため）。
struct PCMChunkAssembler {
    /// 既定 4800 バイト = 24kHz PCM16 mono の 100ms
    let minChunkBytes: Int
    private var buffer = Data()

    init(minChunkBytes: Int = 4800) {
        self.minChunkBytes = minChunkBytes
    }

    mutating func append(_ byte: UInt8) -> Data? {
        buffer.append(byte)
        guard buffer.count >= minChunkBytes else { return nil }
        return drain()
    }

    mutating func append(contentsOf data: Data) -> Data? {
        buffer.append(data)
        guard buffer.count >= minChunkBytes else { return nil }
        return drain()
    }

    /// ストリーム終端で残りを取り出す（奇数の端数バイトは捨てる）。
    mutating func flush() -> Data? {
        drain()
    }

    private mutating func drain() -> Data? {
        let evenCount = buffer.count & ~1
        guard evenCount > 0 else { return nil }
        let chunk = Data(buffer.prefix(evenCount))
        buffer.removeFirst(evenCount)
        return chunk
    }
}
