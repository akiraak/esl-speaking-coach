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
/// ローリング更新クライアント（docs/plans/archive/character-memory.md /
/// docs/plans/archive/per-character-memory.md）。
/// structured outputs `{"learner": string, "chobi": string, "naruko": string}` / ストリーミング
/// （既定モデルは `ClaudeRoute.memoryUpdate`。SSE を蓄積して最後にパースする。
/// SessionFeedbackClient と同型）。
/// 3 本を 1 回の呼び出しで作るのは、transcript を 3 回送らないためと、
/// 「誰の発言か」の解釈が呼び出しごとにぶれて 3 本が矛盾するのを防ぐため。
/// 冪等: 生成が 1 回落ちても前回ノートが残るだけで壊れない。
struct MemoryUpdateClient: Sendable {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// 生成された 3 本。学習者ノートは必須、キャラノートは
    /// **今回そのキャラが自分の話をしなかったときは nil = 前回のノートを維持**する。
    struct UpdatedNotes: Sendable, Equatable {
        let learner: String
        let chobi: String?
        let naruko: String?
    }

    /// 使用モデル（既定は ClaudeRoute の既定。ChatRoomStore が管理画面の選択を詰める）
    var model: ClaudeModel = ClaudeRoute.memoryUpdate.defaultModel

    /// システムプロンプト（固定英文）。
    static let systemPrompt = """
    You maintain the long-term memory of "ESL Group", a voice chat app where a Japanese adult \
    learner practices spoken English with two AI characters, Chobi and Naruko. After each session \
    you receive the memory notes from previous sessions and the transcript of the session that just \
    ended, and you return the updated notes. The notes are shown to the characters at the start of \
    the next session, so they can remember the learner, remember their own lives, and continue the \
    relationship across sessions.

    You return three separate notes.

    ## "learner": the shared note about the learner (at most about four hundred words)

    Plain hyphen bullet lines in exactly two sections:

    About the learner
    - Long-lived facts worth remembering: name, work, family, hobbies, preferences, plans, and \
    similar. Carry facts over from the previous note; update or drop a fact only when the new \
    session contradicts it or clearly makes it outdated.

    Recent sessions
    - One short line per session summarizing what was talked about, oldest first, ending with the \
    session that just ended. As the note approaches the length limit, merge or drop the oldest \
    summaries first so the learner facts always fit.

    ## "chobi" and "naruko": what each character remembers about herself (at most about one \
    hundred and twenty words each)

    Plain hyphen bullet lines, no section titles. Record only what that character said about \
    herself during the sessions: things that happened in her life, promises she made to the \
    learner, and running jokes or shared references between her and the learner. Carry lines over \
    from her previous note, update them when the new session moves them along, and drop the oldest \
    or least useful lines to stay inside the limit.

    Decide whose note a fact belongs to by the speaker tag in the transcript: something said on a \
    "Chobi:" line goes in Chobi's note, something said on a "Naruko:" line goes in Naruko's note. \
    Never put one character's observation about the other into the other character's note; only \
    what a character says about herself counts.

    Do not copy the characters' fixed profiles into their notes. The app already tells them that \
    Chobi loves cats, coffee, and mystery novels and that Naruko loves ramen, karaoke, and mobile \
    games. Record only what actually came up in the conversations, such as a specific new pet, a \
    specific plan, or a specific promise.

    If a character said nothing about herself this session and has no previous note, return an \
    empty string for her. Returning an empty string for a character who does have a previous note \
    keeps the previous note unchanged, so return her previous note when you want to keep it as is.

    ## Rules for all three notes
    - Base the notes only on the previous notes and the transcript. Never invent facts.
    - In the transcript, lines starting with "Learner:" are the learner; lines starting with \
    "Chobi:" or "Naruko:" are the AI characters.
    - The learner's lines come from speech recognition and may contain transcription artifacts; \
    ignore anything that looks like a mis-transcription rather than what the learner meant.
    - Do not record language mistakes, corrections, or any evaluation of the learner's English. \
    The memory is about the people and the conversations, not the learner's language ability.
    - Plain text only: section titles where specified and hyphen bullet lines. No markdown symbols \
    other than the hyphens, no emoji.
    """

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        return URLSession(configuration: configuration)
    }()

    /// 更新済みの記憶ノート 3 本を生成する。previousNotes は前回までのノート（初回は空）、
    /// transcript は話者ラベル付きの会話全文。
    /// usage は SSE の message_start / message_delta から積み上げた利用量（取れなければ nil）。
    func updateMemory(
        apiKey: String, previousNotes: MemoryNotes, topic: String, transcript: String
    ) async throws -> (notes: UpdatedNotes, usage: AIUsageEvent?) {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try Self.makeRequestBody(
            model: model,
            previousNotes: previousNotes, topic: topic, transcript: transcript)

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
        let notes = try Self.parseResult(text: text, stopReason: stopReason)
        let usage: AIUsageEvent? = tokenUsage.isEmpty ? nil : AIUsageEvent(
            provider: .anthropic,
            model: model.rawValue,
            kind: .memoryUpdate,
            inputTokens: tokenUsage.inputTokens,
            outputTokens: tokenUsage.outputTokens,
            cacheReadTokens: tokenUsage.cacheReadInputTokens,
            cacheWriteTokens: tokenUsage.cacheCreationInputTokens)
        return (notes, usage)
    }

    /// リクエストボディを生成する。テストから直接検証できるよう static にしてある。
    static func makeRequestBody(
        model: ClaudeModel = ClaudeRoute.memoryUpdate.defaultModel,
        previousNotes: MemoryNotes, topic: String, transcript: String
    ) throws -> Data {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "learner": ["type": "string"],
                "chobi": ["type": "string"],
                "naruko": ["type": "string"],
            ],
            "required": ["learner", "chobi", "naruko"],
            "additionalProperties": false,
        ]
        let content = """
        Previous memory note about the learner:
        \(Self.previousBlock(previousNotes.learner))

        Previous memory note about Chobi:
        \(Self.previousBlock(previousNotes.chobi))

        Previous memory note about Naruko:
        \(Self.previousBlock(previousNotes.naruko))

        Topic of the session that just ended: \(topic)

        Transcript:
        \(transcript)
        """
        let payload: [String: Any] = [
            "model": model.rawValue,
            // 出力が 3 本ぶんになるので 2000 → 2500（途切れると全体が malformed になる）
            "max_tokens": 2500,
            "stream": true,
            "output_config": ClaudeRequestBody.outputConfig(
                model: model, effort: ClaudeRoute.memoryUpdate.effort, schema: schema),
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

    /// 前回ノートの 1 ブロック（未生成・空白のみは "(none)" を明示する）。
    private static func previousBlock(_ note: String?) -> String {
        SessionOpeningMessage.trimmed(note) ?? "(none)"
    }

    /// 蓄積した出力テキストと stop_reason から更新済みノート 3 本を取り出す。
    /// refusal を先に確認する（CLAUDE.md の規約。content を読む前に判定）。
    /// 学習者ノートが空だとローリング記憶を消してしまうため malformed 扱いにする（3 本とも前回を維持）。
    /// キャラノートの空は正常系（今回そのキャラが自分の話をしなかった）で、nil = 前回維持を意味する。
    static func parseResult(text: String, stopReason: String?) throws -> UpdatedNotes {
        guard stopReason != "refusal" else {
            throw MemoryUpdateError.refusal
        }
        guard let data = text.data(using: .utf8),
              let payload = try? JSONDecoder().decode(MemoryPayload.self, from: data)
        else {
            throw MemoryUpdateError.malformedContent
        }
        guard let learner = SessionOpeningMessage.trimmed(payload.learner) else {
            throw MemoryUpdateError.malformedContent
        }
        return UpdatedNotes(
            learner: learner,
            chobi: SessionOpeningMessage.trimmed(payload.chobi),
            naruko: SessionOpeningMessage.trimmed(payload.naruko))
    }

    private struct MemoryPayload: Decodable {
        let learner: String
        /// schema では required だが、途中のモデル差で欠けても学習者ノートは残せるよう optional で読む
        let chobi: String?
        let naruko: String?
    }
}
