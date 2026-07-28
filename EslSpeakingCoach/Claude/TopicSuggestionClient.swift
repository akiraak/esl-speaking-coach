import Foundation

/// トピックカードに出す候補 1 件（日本語タイトル + フック 1 文）。
/// `genre` は生成時に割り当てた `TopicCatalog` のジャンル id（自作トピック等では nil）。
struct TopicCandidate: Sendable, Equatable, Decodable {
    let title: String
    let hook: String
    var genre: String?

    init(title: String, hook: String, genre: String? = nil) {
        self.title = title
        self.hook = hook
        self.genre = genre
    }
}

enum TopicSuggestionError: Error, LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case refusal
    case malformedContent

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "サーバーから不正な応答が返りました"
        case .httpError(let statusCode, let body):
            return "HTTP \(statusCode): \(body.prefix(300))"
        case .refusal:
            return "トピック生成が拒否されました"
        case .malformedContent:
            return "トピック生成の応答を解釈できませんでした"
        }
    }
}

/// 会話とは別の軽量呼び出しでトピック候補を生成する（conversation-design.md「トピック生成」）。
/// 生成件数は渡した割り当て（`assignments`）の件数に従う
/// （初回起動・🔄 は 3 件、セッション終了後の補充は 1 件。docs/plans/topic-card-carry-over.md）。
/// claude-sonnet-5 / 非ストリーミング / effort low / output_config.format の structured outputs。
/// 固定候補「話しかける」は生成せず、アプリ側で追加する。
struct TopicSuggestionClient: Sendable {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// システムプロンプト（固定英文。付録 B）。
    static let systemPrompt = """
    You generate conversation topic candidates for "ESL Group", a voice chat app where a Japanese \
    adult learner practices spoken English with two AI friends. The user message lists assignments; \
    generate exactly one topic candidate per assignment, in the same order (sometimes a single \
    candidate is requested to refill a card, sometimes a full set of three). The conversation \
    itself happens in English, but the learner picks a topic from a card before speaking, so write \
    title and hook in natural Japanese the learner can grasp at a glance.

    Each request assigns every candidate a genre, a speaking angle, and a difficulty. Follow the \
    assignments: candidate 1 uses assignment 1, and so on. The genre says what the topic is about; \
    the angle says what the learner will be doing with English while talking about it (recalling, \
    comparing, imagining, planning ...). Two topics in the same genre must feel different when the \
    angle differs.

    Rules:
    - Stay inside the assigned genre and angle, but keep the topic concrete and grounded in \
    everyday life. Concrete beats abstract. If a genre feels hard to make concrete, narrow it to a \
    small specific scene rather than drifting to another genre.
    - Do not repeat or closely resemble any topic in the recent-topics list, and do not fall back \
    on stock topics such as morning routines, favorite food, or weekend plans unless the \
    assignment clearly calls for them.
    - title: natural Japanese, roughly four to twelve characters, works as a card label.
    - hook: one short inviting Japanese question or teaser, at most twenty characters.
    - genre: echo the genre_id of the assignment you used, verbatim.
    """

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()

    /// 割り当ての件数ぶん候補を生成する。
    /// recentTitles には重複回避のため直近トピック + 表示中 / 持ち越し候補のタイトルを渡す。
    /// assignments はアプリ側でサンプリングしたジャンル × 話し方 × 難易度の割り当て。
    /// usage は非ストリーミング応答の usage フィールド（取れなければ nil）。
    func suggestTopics(
        apiKey: String, recentTitles: [String], assignments: [TopicAssignment]
    ) async throws -> (topics: [TopicCandidate], usage: AIUsageEvent?) {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try Self.makeRequestBody(
            recentTitles: recentTitles, assignments: assignments)

        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TopicSuggestionError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw TopicSuggestionError.httpError(
                statusCode: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? "")
        }
        return (try Self.parseResponse(data), Self.parseUsage(data))
    }

    /// リクエストボディを生成する。テストから直接検証できるよう static にしてある。
    static func makeRequestBody(
        recentTitles: [String], assignments: [TopicAssignment]
    ) throws -> Data {
        let recentList = recentTitles.isEmpty ? "(none)" : recentTitles.joined(separator: ", ")
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "topics": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "title": ["type": "string"],
                            "hook": ["type": "string"],
                            "genre": ["type": "string"],
                        ],
                        "required": ["title", "hook", "genre"],
                        "additionalProperties": false,
                    ],
                ]
            ],
            "required": ["topics"],
            "additionalProperties": false,
        ]
        let payload: [String: Any] = [
            "model": "claude-sonnet-5",
            "max_tokens": 1024,
            "output_config": [
                "effort": "low",
                "format": [
                    "type": "json_schema",
                    "schema": schema,
                ],
            ],
            "system": Self.systemPrompt,
            "messages": [
                [
                    "role": "user",
                    "content": """
                    Recent topics: \(recentList)

                    Assignments:
                    \(assignmentLines(assignments))
                    """,
                ]
            ],
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    /// 割り当てを user メッセージ用の 1 行 1 件のリストにする。
    static func assignmentLines(_ assignments: [TopicAssignment]) -> String {
        guard !assignments.isEmpty else { return "(none)" }
        return assignments.enumerated().map { index, assignment in
            "\(index + 1). genre_id: \(assignment.genre.id) | genre: \(assignment.genre.english)"
                + " | angle: \(assignment.style.english)"
                + " | difficulty: \(assignment.difficulty.english)"
        }.joined(separator: "\n")
    }

    /// 非ストリーミング応答から候補一覧を取り出す。
    /// stop_reason が refusal のとき content[0] を読むとクラッシュするため先に確認する（CLAUDE.md）。
    static func parseResponse(_ data: Data) throws -> [TopicCandidate] {
        let payload = try JSONDecoder().decode(ResponsePayload.self, from: data)
        guard payload.stopReason != "refusal" else {
            throw TopicSuggestionError.refusal
        }
        guard let text = payload.content?.first(where: { $0.type == "text" })?.text,
              let jsonData = text.data(using: .utf8),
              let result = try? JSONDecoder().decode(TopicsPayload.self, from: jsonData),
              !result.topics.isEmpty
        else {
            throw TopicSuggestionError.malformedContent
        }
        return result.topics
    }

    /// 応答の usage フィールドから利用量を取り出す（料金記録用。失敗しても nil を返すだけ）。
    static func parseUsage(_ data: Data) -> AIUsageEvent? {
        guard let payload = try? JSONDecoder().decode(ResponsePayload.self, from: data),
              let usage = payload.usage else { return nil }
        return AIUsageEvent(
            provider: .anthropic,
            model: "claude-sonnet-5",
            kind: .topicSuggestion,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            cacheReadTokens: usage.cacheReadInputTokens,
            cacheWriteTokens: usage.cacheCreationInputTokens)
    }

    private struct ResponsePayload: Decodable {
        let content: [ContentBlock]?
        let stopReason: String?
        let usage: Usage?

        enum CodingKeys: String, CodingKey {
            case content, usage
            case stopReason = "stop_reason"
        }

        struct ContentBlock: Decodable {
            let type: String?
            let text: String?
        }

        struct Usage: Decodable {
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
        }
    }

    private struct TopicsPayload: Decodable {
        let topics: [TopicCandidate]
    }
}
