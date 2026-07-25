import Foundation

/// セッション後フィードバックの内容（structured outputs で固定するスキーマに対応）。
struct SessionFeedback: Sendable, Equatable, Decodable {
    struct Correction: Sendable, Equatable, Decodable {
        /// 学習者の発話の該当部分
        let original: String
        /// 自然な言い方
        let improved: String
        /// 日本語の短い解説
        let note: String
    }

    struct TryPhrase: Sendable, Equatable, Decodable {
        /// 次に使ってみたい英語表現
        let phrase: String
        /// 日本語の意味
        let meaning: String
    }

    /// Chobi の総評（日本語 2〜3 文。学習者の英語の引用を含み得る）
    let summary: String
    let corrections: [Correction]
    let tryPhrases: [TryPhrase]

    enum CodingKeys: String, CodingKey {
        case summary, corrections
        case tryPhrases = "try_phrases"
    }
}

enum SessionFeedbackError: Error, LocalizedError {
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
            return "フィードバック生成が拒否されました"
        case .malformedContent:
            return "フィードバックの応答を解釈できませんでした"
        }
    }
}

/// セッション終了後に会話全文を評価してフィードバックを生成する（CLAUDE.md「フィードバック生成」）。
/// `claude-opus-5` / effort high / max_tokens 16000 / ストリーミング（SSE を蓄積して最後に
/// structured outputs の JSON をパースする。長い生成でも接続が切れにくい）。
struct SessionFeedbackClient: Sendable {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// システムプロンプト（固定英文。docs/specs/session-feedback.md）。
    static let systemPrompt = """
    You are Chobi, the teacher character of "ESL Group", a voice chat app where a Japanese adult \
    learner practices spoken English with you and Naruko. The learner just finished a session, and \
    you write the post-session feedback. Your feedback helps the learner improve while keeping \
    their motivation high.

    You receive the session topic and transcript. Lines starting with "Learner:" are the learner's \
    utterances, transcribed by speech recognition. Lines starting with "Chobi:" or "Naruko:" are \
    the AI characters.

    Rules:
    - Evaluate only the learner's utterances, never the characters'.
    - Write all explanations in Japanese. Use English only where the English itself is the \
    content: the learner's quoted words, corrected example sentences, and suggested phrases.
    - The learner's lines come from speech recognition, so they may contain transcription \
    artifacts. Only point out errors that are clearly the learner's own language errors; ignore \
    anything that is likely a mis-transcription, such as odd homophones or dropped words that make \
    no sense in context.
    - summary: two or three sentences in Japanese, in Chobi's warm, calm voice, using polite \
    desu-masu style. Mention something specific the learner did well in this session, quoting the \
    learner's English when it helps, then one theme to work on next. No greetings, no questions, \
    no markdown, no emoji.
    - corrections: the most useful corrections only, at most five, ordered by usefulness. Prefer \
    errors that hurt understanding or that the learner repeated. original is what the learner \
    said, shortened to the relevant part. improved is a natural way to say it. note is one short \
    explanation in Japanese, at most about forty characters.
    - try_phrases: two or three natural English expressions that fit conversations like this one \
    and would level up the learner's speech. phrase is the English expression, meaning is a short \
    Japanese translation.
    - If there is little to correct, return fewer corrections. Never invent errors. If the learner \
    spoke very little, keep everything short and encouraging.
    """

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }()

    /// フィードバックを生成する。transcript は話者ラベル付きの会話全文。
    func generateFeedback(
        apiKey: String, topic: String, transcript: String
    ) async throws -> SessionFeedback {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try Self.makeRequestBody(topic: topic, transcript: transcript)

        let (bytes, response) = try await Self.session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SessionFeedbackError.invalidResponse
        }
        guard http.statusCode == 200 else {
            var body = ""
            for try await line in bytes.lines {
                body += line
                if body.count > 2000 { break }
            }
            throw SessionFeedbackError.httpError(statusCode: http.statusCode, body: body)
        }

        var text = ""
        var stopReason: String?
        for try await line in bytes.lines {
            guard let event = try ClaudeSSE.parse(line: line) else { continue }
            switch event {
            case .textDelta(let delta):
                text += delta
            case .messageStopped(let reason):
                stopReason = reason
            }
        }
        return try Self.parseResult(text: text, stopReason: stopReason)
    }

    /// リクエストボディを生成する。テストから直接検証できるよう static にしてある。
    static func makeRequestBody(topic: String, transcript: String) throws -> Data {
        let correctionSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "original": ["type": "string"],
                "improved": ["type": "string"],
                "note": ["type": "string"],
            ],
            "required": ["original", "improved", "note"],
            "additionalProperties": false,
        ]
        let tryPhraseSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "phrase": ["type": "string"],
                "meaning": ["type": "string"],
            ],
            "required": ["phrase", "meaning"],
            "additionalProperties": false,
        ]
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "summary": ["type": "string"],
                "corrections": ["type": "array", "items": correctionSchema],
                "try_phrases": ["type": "array", "items": tryPhraseSchema],
            ],
            "required": ["summary", "corrections", "try_phrases"],
            "additionalProperties": false,
        ]
        let payload: [String: Any] = [
            "model": "claude-opus-5",
            "max_tokens": 16000,
            "stream": true,
            "output_config": [
                "effort": "high",
                "format": [
                    "type": "json_schema",
                    "schema": schema,
                ],
            ],
            "system": [
                [
                    "type": "text",
                    "text": Self.systemPrompt,
                    "cache_control": ["type": "ephemeral"],
                ]
            ],
            "messages": [
                ["role": "user", "content": "Topic: \(topic)\n\nTranscript:\n\(transcript)"]
            ],
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    /// 蓄積した出力テキストと stop_reason から結果を組み立てる。
    /// refusal を先に確認する（CLAUDE.md の規約。content を読む前に判定）。
    static func parseResult(text: String, stopReason: String?) throws -> SessionFeedback {
        guard stopReason != "refusal" else {
            throw SessionFeedbackError.refusal
        }
        guard let data = text.data(using: .utf8),
              let feedback = try? JSONDecoder().decode(SessionFeedback.self, from: data)
        else {
            throw SessionFeedbackError.malformedContent
        }
        return feedback
    }
}
