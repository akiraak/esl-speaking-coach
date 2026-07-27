import Foundation

enum TranslationError: Error, LocalizedError {
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
            return "翻訳が拒否されました"
        case .malformedContent:
            return "翻訳の応答を解釈できませんでした"
        }
    }
}

/// 会話の発話をまとめて日本語訳するクライアント（docs/plans/message-translation.md）。
/// `claude-haiku-4-5` / 非ストリーミング / structured outputs で `[{id, ja}]` を受け取る。
/// 短文の英日翻訳に sonnet は過剰なため haiku を使う（$1 / $5 per 1M）。
/// **`output_config.effort` は haiku-4-5 では 400 になるため送らない**
/// （`temperature` / `top_p` / `top_k` も従来どおり送らない）。
struct TranslationClient: Sendable {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// 翻訳対象の 1 発話。id は発話 ID（レスポンスの突き合わせに使う）。
    struct Item: Sendable, Equatable {
        let id: UUID
        /// 話者ラベル（Chobi / Naruko / Learner）
        let speaker: String
        let text: String
    }

    /// 文脈として渡す発話（訳出しない・参照専用なので id は持たない）。
    struct ContextLine: Sendable, Equatable {
        let speaker: String
        let text: String
    }

    /// 文脈として渡す直前発話の件数。
    static let contextLineLimit = 8

    /// システムプロンプト（固定英文）。文脈は訳出せず対象発話だけを返させる。
    static let systemPrompt = """
    You translate spoken English into natural Japanese for "ESL Group", a voice chat app where a \
    Japanese adult learner practices spoken English with two AI characters, Chobi and Naruko. The \
    learner reads your translations next to the original English to check what was said.

    Each request has two parts. The "Context" part is previous lines of the same conversation, \
    given for reference only. The "Translate" part lists the utterances to translate, each with an \
    id. Translate only the lines in the "Translate" part, and return one entry per id.

    Rules:
    - Use the context to resolve pronouns, ellipsis, and short replies such as "Yeah, I did." or \
    "That one." A line that is vague on its own should still read naturally in Japanese.
    - Write natural spoken Japanese, not a word-by-word gloss. Keep the register casual and \
    friendly, matching a relaxed conversation between friends.
    - Lines spoken by "Learner" come from speech recognition and may contain transcription \
    artifacts. Translate what was most likely meant; do not comment on the errors.
    - Keep proper nouns, place names, and product names as they are when that reads more naturally.
    - Output only the translation for each id. No notes, no explanations, no romaji, no quotes \
    around the whole line.
    """

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()

    /// 発話をまとめて翻訳する。戻り値は発話 ID → 日本語訳。
    /// usage は非ストリーミング応答の usage フィールド（取れなければ nil）。
    func translate(
        apiKey: String, topic: String?, context: [ContextLine], targets: [Item]
    ) async throws -> (translations: [UUID: String], usage: AIUsageEvent?) {
        guard !targets.isEmpty else { return ([:], nil) }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try Self.makeRequestBody(
            topic: topic, context: context, targets: targets)

        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranslationError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw TranslationError.httpError(
                statusCode: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? "")
        }
        return (try Self.parseResponse(data), Self.parseUsage(data))
    }

    /// リクエストボディを生成する。テストから直接検証できるよう static にしてある。
    /// 文脈（トピック + 直前発話）は id を振らずに渡し、訳出対象と区別する。
    static func makeRequestBody(
        topic: String?, context: [ContextLine], targets: [Item]
    ) throws -> Data {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "translations": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "id": ["type": "string"],
                            "ja": ["type": "string"],
                        ],
                        "required": ["id", "ja"],
                        "additionalProperties": false,
                    ],
                ]
            ],
            "required": ["translations"],
            "additionalProperties": false,
        ]
        let trimmedTopic = topic?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let contextBody = context.isEmpty
            ? "(none)"
            : context.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
        let targetBody = targets
            .map { "[\($0.id.uuidString)] \($0.speaker): \($0.text)" }
            .joined(separator: "\n")
        let content = """
        Topic: \(trimmedTopic.isEmpty ? "(none)" : trimmedTopic)

        Context (for reference only, do not translate):
        \(contextBody)

        Translate (one entry per id):
        \(targetBody)
        """
        let payload: [String: Any] = [
            "model": "claude-haiku-4-5",
            "max_tokens": 4096,
            "output_config": [
                "format": [
                    "type": "json_schema",
                    "schema": schema,
                ]
            ],
            "system": Self.systemPrompt,
            "messages": [
                ["role": "user", "content": content]
            ],
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    /// 非ストリーミング応答から id → 訳の対応を取り出す。
    /// stop_reason が refusal のとき content[0] を読むとクラッシュするため先に確認する（CLAUDE.md）。
    static func parseResponse(_ data: Data) throws -> [UUID: String] {
        let payload = try JSONDecoder().decode(ResponsePayload.self, from: data)
        guard payload.stopReason != "refusal" else {
            throw TranslationError.refusal
        }
        guard let text = payload.content?.first(where: { $0.type == "text" })?.text,
              let jsonData = text.data(using: .utf8),
              let result = try? JSONDecoder().decode(TranslationsPayload.self, from: jsonData)
        else {
            throw TranslationError.malformedContent
        }
        var translations: [UUID: String] = [:]
        for entry in result.translations {
            guard let id = UUID(uuidString: entry.id) else { continue }
            let ja = entry.ja.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ja.isEmpty else { continue }
            translations[id] = ja
        }
        guard !translations.isEmpty else {
            throw TranslationError.malformedContent
        }
        return translations
    }

    /// 応答の usage フィールドから利用量を取り出す（料金記録用。失敗しても nil を返すだけ）。
    static func parseUsage(_ data: Data) -> AIUsageEvent? {
        guard let payload = try? JSONDecoder().decode(ResponsePayload.self, from: data),
              let usage = payload.usage else { return nil }
        return AIUsageEvent(
            provider: .anthropic,
            model: "claude-haiku-4-5",
            kind: .translation,
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

    private struct TranslationsPayload: Decodable {
        struct Entry: Decodable {
            let id: String
            let ja: String
        }
        let translations: [Entry]
    }
}
