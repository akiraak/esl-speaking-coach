import Foundation

/// ストリーミング応答から会話ロジックが必要とする最小のイベント。
enum ClaudeStreamEvent: Sendable, Equatable {
    case textDelta(String)
    /// message_delta で通知される stop_reason（"end_turn" / "max_tokens" / "refusal" など）
    case messageStopped(stopReason: String?)
}

enum ClaudeClientError: Error, LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "サーバーから不正な応答が返りました"
        case .httpError(let statusCode, let body):
            return "HTTP \(statusCode): \(body.prefix(300))"
        case .apiError(let message):
            return "Claude API エラー: \(message)"
        }
    }
}

/// Claude Messages API のストリーミングクライアント。
/// Swift の公式 SDK は存在しないため、URLSession で raw HTTP を叩き SSE を自前でパースする（CLAUDE.md の規約）。
/// temperature / top_p / top_k は claude-opus-5 では 400 になるため、リクエスト型自体に持たせない。
struct ClaudeMessagesClient: Sendable {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// 会話ターン用の設定（ストリーミング必須・effort low・max_tokens は意図的に小さく）。
    /// 会話ターンのモデルは claude-sonnet-5（2026-07-25 決定。記録: docs/plans/archive/spike-conversation/）。
    struct TurnParameters: Sendable {
        var model = "claude-sonnet-5"
        var maxTokens = 1024
        var effort = "low"
    }

    var parameters = TurnParameters()

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        return URLSession(configuration: configuration)
    }()

    func streamReply(
        apiKey: String,
        system: String,
        messages: [ConversationMessage]
    ) -> AsyncThrowingStream<ClaudeStreamEvent, Error> {
        let parameters = parameters
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: Self.endpoint)
                    request.httpMethod = "POST"
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    request.setValue("application/json", forHTTPHeaderField: "content-type")
                    request.httpBody = try Self.makeRequestBody(
                        parameters: parameters, system: system, messages: messages)

                    let (bytes, response) = try await Self.session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw ClaudeClientError.invalidResponse
                    }
                    guard http.statusCode == 200 else {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                            if body.count > 2000 { break }
                        }
                        throw ClaudeClientError.httpError(statusCode: http.statusCode, body: body)
                    }
                    for try await line in bytes.lines {
                        if let event = try ClaudeSSE.parse(line: line) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// リクエストボディを生成する。テストから直接検証できるよう static にしてある。
    static func makeRequestBody(
        parameters: TurnParameters,
        system: String,
        messages: [ConversationMessage]
    ) throws -> Data {
        let body = RequestBody(
            model: parameters.model,
            maxTokens: parameters.maxTokens,
            stream: true,
            outputConfig: .init(effort: parameters.effort),
            system: [.init(text: system)],
            messages: messages.map { .init(role: $0.role.rawValue, content: $0.text) }
        )
        return try JSONEncoder().encode(body)
    }

    private struct RequestBody: Encodable {
        let model: String
        let maxTokens: Int
        let stream: Bool
        let outputConfig: OutputConfig
        let system: [SystemBlock]
        let messages: [Message]

        enum CodingKeys: String, CodingKey {
            case model, stream, system, messages
            case maxTokens = "max_tokens"
            case outputConfig = "output_config"
        }

        struct OutputConfig: Encodable {
            let effort: String
        }

        /// システムプロンプトは固定文 + cache_control でプロンプトキャッシュを効かせる。
        struct SystemBlock: Encodable {
            let type = "text"
            let text: String
            let cacheControl = CacheControl()

            enum CodingKeys: String, CodingKey {
                case type, text
                case cacheControl = "cache_control"
            }

            struct CacheControl: Encodable {
                let type = "ephemeral"
            }
        }

        struct Message: Encodable {
            let role: String
            let content: String
        }
    }
}

/// SSE の 1 行を Claude のストリームイベントへ変換する。
enum ClaudeSSE {
    /// `data: {...}` 以外の行（event 行・空行・ping 等）は nil を返す。
    /// API の error イベントは throw する。
    static func parse(line: String) throws -> ClaudeStreamEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }

        switch payload.type {
        case "content_block_delta":
            // thinking_delta 等は読み上げ対象外。text_delta のみ拾う
            guard payload.delta?.type == "text_delta", let text = payload.delta?.text else { return nil }
            return .textDelta(text)
        case "message_delta":
            return .messageStopped(stopReason: payload.delta?.stopReason)
        case "error":
            throw ClaudeClientError.apiError(payload.error?.message ?? "unknown error")
        default:
            return nil
        }
    }

    private struct Payload: Decodable {
        let type: String
        let delta: Delta?
        let error: APIError?

        struct Delta: Decodable {
            let type: String?
            let text: String?
            let stopReason: String?

            enum CodingKeys: String, CodingKey {
                case type, text
                case stopReason = "stop_reason"
            }
        }

        struct APIError: Decodable {
            let type: String?
            let message: String?
        }
    }
}
