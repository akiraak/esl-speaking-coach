import Foundation

/// Alibaba Model Studio の Qwen3-ASR リアルタイム認識（WebSocket）の設定。
/// 検証用の切替経路（docs/plans/alibaba-voice-models.md）。既定の STT は gpt-live-transcribe のまま。
struct QwenTranscriptionConfiguration: Sendable {
    /// -stt-model qwen3-asr-flash-realtime で選択される
    var model = "qwen3-asr-flash-realtime"
    /// 認識言語の固定。会話は英語のみ（CLAUDE.md）なので en 固定
    var language = "en"
    /// 入力サンプルレート。公式ドキュメントは pcm 8/16kHz のみ
    /// （24kHz も実測では通ったがドキュメント外挙動のため 16kHz を使う）
    var sampleRate = 16000

    var websocketURL: URL {
        URL(string: "wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime?model=\(model)")!
    }
}

/// クライアント → サーバのイベント。event_id は必須（UUID）。
enum QwenTranscriptionClientEvent {
    static func sessionUpdate(configuration: QwenTranscriptionConfiguration) throws -> Data {
        try serialize([
            "type": "session.update",
            "session": [
                "modalities": ["text"],
                "input_audio_format": "pcm",
                "sample_rate": configuration.sampleRate,
                "input_audio_transcription": ["language": configuration.language],
                // manual mode（クライアント VAD + 手動 commit）。サーバ VAD は使わない
                "turn_detection": NSNull(),
            ],
        ])
    }

    static func inputAudioAppend(base64Audio: String) throws -> Data {
        try serialize(["type": "input_audio_buffer.append", "audio": base64Audio])
    }

    static func inputAudioCommit() throws -> Data {
        try serialize(["type": "input_audio_buffer.commit"])
    }

    private static func serialize(_ object: [String: Any]) throws -> Data {
        var payload = object
        payload["event_id"] = UUID().uuidString
        return try JSONSerialization.data(withJSONObject: payload)
    }
}

/// サーバ → クライアントのイベント。必要な最小のみ拾う。
enum QwenTranscriptionServerEvent: Sendable, Equatable {
    case sessionCreated
    case sessionUpdated
    /// 認識途中。text（確定 prefix）+ stash（未確定の続き）を連結した累積テキスト
    case partial(String)
    case completed(String, usage: STTSegmentUsage?)
    case serverError(message: String, ignorable: Bool)
    case ignored(type: String)

    static func parse(_ text: String) -> QwenTranscriptionServerEvent {
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String
        else {
            return .ignored(type: "(unparsable)")
        }

        switch type {
        case "session.created":
            return .sessionCreated
        case "session.updated":
            return .sessionUpdated
        case "conversation.item.input_audio_transcription.text":
            let fixed = object["text"] as? String ?? ""
            let stash = object["stash"] as? String ?? ""
            return .partial(fixed + stash)
        case "conversation.item.input_audio_transcription.completed":
            return .completed(
                object["transcript"] as? String ?? "",
                usage: parseUsage(object["usage"] as? [String: Any]))
        case "error":
            let error = object["error"] as? [String: Any]
            let code = error?["code"] as? String ?? ""
            let param = error?["param"] as? String ?? ""
            let message = error?["message"] as? String ?? "unknown error"
            // バッファ操作系（空 commit 等）はセグメント 1 個の欠落で済むため継続する
            let ignorable = code.hasPrefix("input_audio_buffer")
                || param.hasPrefix("input_audio_buffer")
                || message.contains("input_audio_buffer")
            return .serverError(message: message, ignorable: ignorable)
        default:
            return .ignored(type: type)
        }
    }

    /// Qwen の usage は duration（秒・整数）とトークン内訳が両建てで届く。
    /// 課金は $0.000090/秒の秒数ベース（AIPricing 側もそちらを使う）。
    private static func parseUsage(_ object: [String: Any]?) -> STTSegmentUsage? {
        guard let object else { return nil }
        let inputDetails = object["input_tokens_details"] as? [String: Any]
        let seconds: Double?
        if let duration = object["duration"] as? Double {
            seconds = duration
        } else if let duration = object["duration"] as? Int {
            seconds = Double(duration)
        } else {
            seconds = nil
        }
        return STTSegmentUsage(
            audioInputTokens: inputDetails?["audio_tokens"] as? Int,
            textInputTokens: inputDetails?["text_tokens"] as? Int,
            outputTokens: object["output_tokens"] as? Int,
            audioSeconds: seconds)
    }
}

/// Qwen3-ASR リアルタイム認識（WebSocket）の実装。manual mode（turn_detection: null +
/// 手動 commit）で動かすため、クライアント VAD + 送信ゲートの現行フローがそのまま使える。
/// イベント体系は OpenAI Realtime とほぼ同型（OpenAITranscriptionStream を雛形にしている）。
/// インスタンスは使い捨て（connect → stop。再接続は作り直す）。
@MainActor
final class QwenTranscriptionStream: StreamingSpeechTranscriber {
    let events: AsyncStream<STTStreamEvent>

    private static let urlSession = URLSession(configuration: .default)

    private let eventContinuation: AsyncStream<STTStreamEvent>.Continuation
    private let configuration: QwenTranscriptionConfiguration
    private let apiKey: String

    private var webSocket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    /// 送信順を保証する直列キュー（session.update → 音声チャンク → commit の順序保証）。
    private var sendQueue: AsyncStream<Data>.Continuation?
    /// commit 済みで completed 待ちのセグメントが「破棄扱いか」の FIFO。
    /// Qwen は input_audio_buffer.clear 非対応（実測で invalid_value）のため、
    /// clearClientBuffer は「commit して結果を読み捨てる」ことで代替する
    private var pendingCommitIsDiscard: [Bool] = []
    private var isStopped = false
    /// 切断は 1 回だけ通知する（ping 失敗と receive 失敗が両方検知したときの二重通知防止）。
    private var didReportClose = false

    init(configuration: QwenTranscriptionConfiguration = QwenTranscriptionConfiguration(), apiKey: String) {
        self.configuration = configuration
        self.apiKey = apiKey
        (events, eventContinuation) = AsyncStream.makeStream(
            of: STTStreamEvent.self, bufferingPolicy: .unbounded)
    }

    func connect() {
        guard webSocket == nil, !isStopped else { return }
        var request = URLRequest(url: configuration.websocketURL)
        request.setValue("bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let task = Self.urlSession.webSocketTask(with: request)
        webSocket = task
        task.resume()
        startSender(webSocket: task)
        startPingLoop(webSocket: task)

        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let socket = self?.webSocket else { return }
                do {
                    let message = try await socket.receive()
                    guard let self, !self.isStopped else { return }
                    let text: String?
                    switch message {
                    case .string(let string): text = string
                    case .data(let data): text = String(data: data, encoding: .utf8)
                    @unknown default: text = nil
                    }
                    if let text {
                        self.handle(QwenTranscriptionServerEvent.parse(text))
                    }
                } catch {
                    self?.handleSocketClosed(error)
                    return
                }
            }
        }
    }

    func sendAudio(_ chunk: Data) {
        guard !isStopped else { return }
        guard let data = try? QwenTranscriptionClientEvent.inputAudioAppend(
            base64Audio: chunk.base64EncodedString()) else { return }
        sendQueue?.yield(data)
    }

    func noteClientSpeechStarted() {
        guard !isStopped else { return }
        eventContinuation.yield(.speechStarted)
    }

    func commitClientSegment() {
        guard !isStopped else { return }
        if let data = try? QwenTranscriptionClientEvent.inputAudioCommit() {
            pendingCommitIsDiscard.append(false)
            sendQueue?.yield(data)
        }
        eventContinuation.yield(.speechStopped)
    }

    /// 発話の途中で入力ゲートが閉じた。clear が無いので commit して結果を読み捨てる
    /// （利用量イベントだけは流す。破棄セグメントも appended 分は課金されるため）。
    func clearClientBuffer() {
        guard !isStopped else { return }
        if let data = try? QwenTranscriptionClientEvent.inputAudioCommit() {
            pendingCommitIsDiscard.append(true)
            sendQueue?.yield(data)
        }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        receiveTask?.cancel()
        sendTask?.cancel()
        pingTask?.cancel()
        receiveTask = nil
        sendTask = nil
        pingTask = nil
        sendQueue?.finish()
        sendQueue = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        eventContinuation.finish()
    }

    private func startSender(webSocket: URLSessionWebSocketTask) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Data.self, bufferingPolicy: .unbounded)
        sendQueue = continuation
        sendTask = Task {
            for await data in stream {
                guard !Task.isCancelled else { return }
                guard let text = String(data: data, encoding: .utf8) else { continue }
                do {
                    try await webSocket.send(.string(text))
                } catch {
                    // 送信失敗は受信側の切断検知に任せる（audio append は高頻度なので二重通知しない）
                    return
                }
            }
        }
    }

    /// ネットワーク切替等で receive がエラーも返さず沈黙するケースを検知するための keepalive。
    private func startPingLoop(webSocket: URLSessionWebSocketTask) {
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, !self.isStopped, !Task.isCancelled else { return }
                do {
                    try await Self.ping(webSocket)
                } catch {
                    self.handleSocketClosed(error)
                    return
                }
            }
        }
    }

    private static func ping(_ webSocket: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            webSocket.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func handleSocketClosed(_ error: Error) {
        guard !isStopped, !didReportClose else { return }
        didReportClose = true
        var detail = error.localizedDescription
        if let webSocket, webSocket.closeCode != .invalid {
            let reason = webSocket.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            detail += " (close=\(webSocket.closeCode.rawValue) \(reason))"
        }
        eventContinuation.yield(.connectionFailed("STT 接続が切れました: \(detail)"))
    }

    private func handle(_ event: QwenTranscriptionServerEvent) {
        switch event {
        case .sessionCreated:
            if let data = try? QwenTranscriptionClientEvent.sessionUpdate(configuration: configuration) {
                sendQueue?.yield(data)
            }

        case .sessionUpdated:
            eventContinuation.yield(.ready)

        case .partial(let transcript):
            // 破棄待ちのセグメントの partial は表示しない
            guard pendingCommitIsDiscard.first != true else { return }
            eventContinuation.yield(.partialTranscript(transcript))

        case .completed(let transcript, let usage):
            let isDiscard = pendingCommitIsDiscard.isEmpty
                ? false : pendingCommitIsDiscard.removeFirst()
            if let usage {
                eventContinuation.yield(.segmentUsage(usage))
            }
            if !isDiscard {
                eventContinuation.yield(.finalTranscript(transcript))
            }

        case .serverError(let message, let ignorable):
            if ignorable {
                // commit に対して completed が返らないケース。FIFO のずれを最小に留める
                if !pendingCommitIsDiscard.isEmpty {
                    pendingCommitIsDiscard.removeFirst()
                }
                eventContinuation.yield(.notice(message))
            } else if !didReportClose {
                didReportClose = true
                eventContinuation.yield(.connectionFailed("STT API エラー: \(message)"))
            }

        case .ignored:
            break
        }
    }
}
