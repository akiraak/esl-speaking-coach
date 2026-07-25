import Foundation

/// トピックカードに出す候補 1 件（英語タイトル + フック 1 文）。
struct TopicCandidate: Sendable, Equatable, Decodable {
    let title: String
    let hook: String
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

/// 会話とは別の軽量呼び出しでトピック候補 3 件を生成する（conversation-design.md「トピック生成」）。
/// claude-sonnet-5 / 非ストリーミング / effort low / output_config.format の structured outputs。
/// 「Free talk」は生成せず、アプリ側で固定候補として追加する。
struct TopicSuggestionClient: Sendable {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// システムプロンプト（固定英文。付録 B）。
    static let systemPrompt = """
    You generate conversation topic candidates for "ESL Group", a voice chat app where a Japanese \
    adult learner practices spoken English with two AI friends. Generate exactly three topic \
    candidates the learner can pick from.

    Rules:
    - Topics are about everyday life: daily routines, food, travel, work, hobbies, movies, plans, \
    small personal stories. Concrete beats abstract.
    - Vary the three candidates: different genres, and a mix of easy and slightly challenging.
    - Do not repeat or closely resemble any topic in the recent-topics list.
    - title: three to six words, natural English, works as a card label.
    - hook: one short inviting question or teaser, at most twelve words.
    """

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()

    /// 候補 3 件を生成する。recentTitles には重複回避のため直近トピック + 表示中候補のタイトルを渡す。
    func suggestTopics(apiKey: String, recentTitles: [String]) async throws -> [TopicCandidate] {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try Self.makeRequestBody(recentTitles: recentTitles)

        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TopicSuggestionError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw TopicSuggestionError.httpError(
                statusCode: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? "")
        }
        return try Self.parseResponse(data)
    }

    /// リクエストボディを生成する。テストから直接検証できるよう static にしてある。
    static func makeRequestBody(recentTitles: [String]) throws -> Data {
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
                        ],
                        "required": ["title", "hook"],
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
                ["role": "user", "content": "Recent topics: \(recentList)"]
            ],
        ]
        return try JSONSerialization.data(withJSONObject: payload)
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

    private struct ResponsePayload: Decodable {
        let content: [ContentBlock]?
        let stopReason: String?

        enum CodingKeys: String, CodingKey {
            case content
            case stopReason = "stop_reason"
        }

        struct ContentBlock: Decodable {
            let type: String?
            let text: String?
        }
    }

    private struct TopicsPayload: Decodable {
        let topics: [TopicCandidate]
    }
}
