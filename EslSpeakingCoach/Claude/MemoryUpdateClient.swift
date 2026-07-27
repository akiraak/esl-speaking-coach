import Foundation

enum MemoryUpdateError: Error, LocalizedError {
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
            return "記憶の更新が拒否されました"
        case .malformedContent:
            return "記憶更新の応答を解釈できませんでした"
        }
    }
}

/// セッション終了後に「前回までの記憶ノート + 今回の transcript → 更新済みノート」を生成する
/// ローリング更新クライアント（docs/plans/character-memory.md）。
/// `claude-sonnet-5` / structured outputs `{"memory": string}` / ストリーミング
/// （SSE を蓄積して最後にパースする。SessionFeedbackClient と同型）。
/// 冪等: 生成が 1 回落ちても前回ノートが残るだけで壊れない。
struct MemoryUpdateClient: Sendable {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// システムプロンプト（固定英文）。
    static let systemPrompt = """
    You maintain the long-term memory of "ESL Group", a voice chat app where a Japanese adult \
    learner practices spoken English with two AI characters, Chobi and Naruko. After each session \
    you receive the memory note from previous sessions and the transcript of the session that just \
    ended, and you return the updated memory note. The note is shown to the characters at the \
    start of the next session, so they can remember the learner and continue the relationship \
    across sessions.

    Write the updated note in English as plain hyphen bullet lines, at most about four hundred \
    words in total, in exactly two sections:

    About the learner
    - Long-lived facts worth remembering: name, work, family, hobbies, preferences, plans, and \
    similar. Carry facts over from the previous note; update or drop a fact only when the new \
    session contradicts it or clearly makes it outdated.

    Recent sessions
    - One short line per session summarizing what was talked about, oldest first, ending with the \
    session that just ended. As the note approaches the length limit, merge or drop the oldest \
    summaries first so the learner facts always fit.

    Rules:
    - Base the note only on the previous note and the transcript. Never invent facts.
    - In the transcript, lines starting with "Learner:" are the learner. Lines starting with \
    "Chobi:" or "Naruko:" are the AI characters; record a character's statement only when the \
    characters must stay consistent with it later, such as a promise they made.
    - The learner's lines come from speech recognition and may contain transcription artifacts; \
    ignore anything that looks like a mis-transcription rather than what the learner meant.
    - Do not record language mistakes, corrections, or any evaluation of the learner's English. \
    The memory is about the person and the conversations, not their language ability.
    - Plain text only: the two section titles and hyphen bullet lines. No markdown symbols other \
    than the hyphens, no emoji.
    """

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        return URLSession(configuration: configuration)
    }()

    /// 更新済みの記憶ノートを生成する。previousMemory は前回までのノート（初回は nil）、
    /// transcript は話者ラベル付きの会話全文。
    /// usage は SSE の message_start / message_delta から積み上げた利用量（取れなければ nil）。
    func updateMemory(
        apiKey: String, previousMemory: String?, topic: String, transcript: String
    ) async throws -> (memory: String, usage: AIUsageEvent?) {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try Self.makeRequestBody(
            previousMemory: previousMemory, topic: topic, transcript: transcript)

        let (bytes, response) = try await Self.session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MemoryUpdateError.invalidResponse
        }
        guard http.statusCode == 200 else {
            var body = ""
            for try await line in bytes.lines {
                body += line
                if body.count > 2000 { break }
            }
            throw MemoryUpdateError.httpError(statusCode: http.statusCode, body: body)
        }

        var text = ""
        var stopReason: String?
        var tokenUsage = ClaudeTokenUsage()
        for try await line in bytes.lines {
            for event in try ClaudeSSE.parse(line: line) {
                switch event {
                case .textDelta(let delta):
                    text += delta
                case .messageStopped(let reason):
                    stopReason = reason
                case .usageUpdated(let usage):
                    tokenUsage.merge(usage)
                }
            }
        }
        let memory = try Self.parseResult(text: text, stopReason: stopReason)
        let usage: AIUsageEvent? = tokenUsage.isEmpty ? nil : AIUsageEvent(
            provider: .anthropic,
            model: "claude-sonnet-5",
            kind: .memoryUpdate,
            inputTokens: tokenUsage.inputTokens,
            outputTokens: tokenUsage.outputTokens,
            cacheReadTokens: tokenUsage.cacheReadInputTokens,
            cacheWriteTokens: tokenUsage.cacheCreationInputTokens)
        return (memory, usage)
    }

    /// リクエストボディを生成する。テストから直接検証できるよう static にしてある。
    static func makeRequestBody(
        previousMemory: String?, topic: String, transcript: String
    ) throws -> Data {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "memory": ["type": "string"]
            ],
            "required": ["memory"],
            "additionalProperties": false,
        ]
        let previous = previousMemory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let content = """
        Previous memory note:
        \(previous.isEmpty ? "(none)" : previous)

        Topic of the session that just ended: \(topic)

        Transcript:
        \(transcript)
        """
        let payload: [String: Any] = [
            "model": "claude-sonnet-5",
            "max_tokens": 2000,
            "stream": true,
            "output_config": [
                "effort": "medium",
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
                ["role": "user", "content": content]
            ],
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    /// 蓄積した出力テキストと stop_reason から更新済みノートを取り出す。
    /// refusal を先に確認する（CLAUDE.md の規約。content を読む前に判定）。
    /// 空ノートはローリング記憶を消してしまうため malformed 扱いにする（前回ノートを維持）。
    static func parseResult(text: String, stopReason: String?) throws -> String {
        guard stopReason != "refusal" else {
            throw MemoryUpdateError.refusal
        }
        guard let data = text.data(using: .utf8),
              let payload = try? JSONDecoder().decode(MemoryPayload.self, from: data)
        else {
            throw MemoryUpdateError.malformedContent
        }
        let memory = payload.memory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !memory.isEmpty else {
            throw MemoryUpdateError.malformedContent
        }
        return memory
    }

    private struct MemoryPayload: Decodable {
        let memory: String
    }
}
