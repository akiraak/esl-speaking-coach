import Foundation

/// ストリーミング応答から会話ロジックが必要とする最小のイベント。
enum ClaudeStreamEvent: Sendable, Equatable {
    case textDelta(String)
    /// message_delta で通知される stop_reason（"end_turn" / "max_tokens" / "refusal" など）
    case messageStopped(stopReason: String?)
    /// usage の更新（message_start で入力側、message_delta で出力側が届く）。
    /// 呼び出し側は merge で 1 ターン分に積み上げる
    case usageUpdated(ClaudeTokenUsage)
}

/// Claude Messages API の usage（管理画面の料金記録用）。
struct ClaudeTokenUsage: Sendable, Equatable {
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheReadInputTokens: Int?
    var cacheCreationInputTokens: Int?

    var isEmpty: Bool {
        inputTokens == nil && outputTokens == nil
            && cacheReadInputTokens == nil && cacheCreationInputTokens == nil
    }

    /// 後から届いた値で上書きする（nil は既存値を保持）。
    mutating func merge(_ other: ClaudeTokenUsage) {
        inputTokens = other.inputTokens ?? inputTokens
        outputTokens = other.outputTokens ?? outputTokens
        cacheReadInputTokens = other.cacheReadInputTokens ?? cacheReadInputTokens
        cacheCreationInputTokens = other.cacheCreationInputTokens ?? cacheCreationInputTokens
    }
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
    /// 既定のモデルと effort は `ClaudeRoute.conversationTurn` が正
    /// （2026-07-25 に sonnet-5 で決定。記録: docs/plans/archive/spike-conversation/。
    /// 管理画面から切り替えられる: docs/plans/model-selection-in-admin.md）。
    struct TurnParameters: Sendable {
        var model: ClaudeModel
        var maxTokens: Int
        /// nil なら `output_config` ごと送らない。モデルが effort 非対応なら送信時に落とす
        var effort: String?

        /// max_tokens は thinking と本文で共有する予算なのでモデルから決める（明示指定も可）。
        init(
            model: ClaudeModel = ClaudeRoute.conversationTurn.defaultModel,
            maxTokens: Int? = nil,
            effort: String? = ClaudeRoute.conversationTurn.effort
        ) {
            self.model = model
            self.maxTokens = maxTokens ?? model.turnMaxTokens
            self.effort = effort
        }
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
                        for event in try ClaudeSSE.parse(line: line) {
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
        // effort 非対応のモデル（haiku-4-5）へ送ると 400 になるので output_config ごと落とす
        let effort = parameters.model.supportsEffort ? parameters.effort : nil
        let body = RequestBody(
            model: parameters.model.rawValue,
            maxTokens: parameters.maxTokens,
            stream: true,
            outputConfig: effort.map { RequestBody.OutputConfig(effort: $0) },
            system: [.init(text: system)],
            messages: messages.map { .init(role: $0.role.rawValue, content: $0.text) }
        )
        return try JSONEncoder().encode(body)
    }

    private struct RequestBody: Encodable {
        let model: String
        let maxTokens: Int
        let stream: Bool
        let outputConfig: OutputConfig?
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
    /// `data: {...}` 以外の行（event 行・空行・ping 等）は空配列を返す。
    /// API の error イベントは throw する。
    /// message_delta は usage → stop の順で 2 イベントになり得る。
    ///
    /// デコードできない `data:` 行は**捨てる**（挙動は従来どおり）が、
    /// 捨てたことを診断ログへ残す。1 行が途中で割れるとその行のテキストが丸ごと消え、
    /// それでも残りは JSON として通ってしまうため、文章だけが欠ける形になる
    /// （docs/plans/feedback-truncated.md H1）。
    static func parse(line: String) throws -> [ClaudeStreamEvent] {
        guard line.hasPrefix("data:") else { return [] }
        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return [] }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            DiagnosticsLog.record(
                "!! sse: data 行を解釈できず破棄 len=\(json.count) "
                + "body=\(DiagnosticsSnippet.make(String(json), limit: 200))")
            return []
        }

        switch payload.type {
        case "content_block_delta":
            // thinking_delta 等は読み上げ対象外。text_delta のみ拾う
            guard payload.delta?.type == "text_delta", let text = payload.delta?.text else { return [] }
            return [.textDelta(text)]
        case "message_start":
            // 入力側の usage（input_tokens / cache_*）は message_start に載る
            guard let usage = payload.message?.usage?.tokenUsage else { return [] }
            return [.usageUpdated(usage)]
        case "message_delta":
            var events: [ClaudeStreamEvent] = []
            if let usage = payload.usage?.tokenUsage {
                events.append(.usageUpdated(usage))
            }
            events.append(.messageStopped(stopReason: payload.delta?.stopReason))
            return events
        case "error":
            let message = payload.error?.message ?? "unknown error"
            DiagnosticsLog.record("!! sse: error イベント type=\(payload.error?.type ?? "-") \(message)")
            throw ClaudeClientError.apiError(message)
        default:
            return []
        }
    }

    private struct Payload: Decodable {
        let type: String
        let delta: Delta?
        let message: MessageInfo?
        let usage: UsageInfo?
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

        struct MessageInfo: Decodable {
            let usage: UsageInfo?
        }

        struct UsageInfo: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
            let cacheReadInputTokens: Int?
            let cacheCreationInputTokens: Int?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
            }

            var tokenUsage: ClaudeTokenUsage? {
                let usage = ClaudeTokenUsage(
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cacheReadInputTokens: cacheReadInputTokens,
                    cacheCreationInputTokens: cacheCreationInputTokens)
                return usage.isEmpty ? nil : usage
            }
        }

        struct APIError: Decodable {
            let type: String?
            let message: String?
        }
    }
}
