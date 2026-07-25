import Foundation

/// gpt-4o-transcribe の WebSocket ストリーミング実装（OpenAI Realtime API の transcription セッション）。
/// サーバイベントは案 B と同じ GA 形式のため RealtimeServerEvent のパーサを共用する。
/// インスタンスは使い捨て（connect → stop。再接続は作り直す）。
@MainActor
final class OpenAITranscriptionStream: StreamingSpeechTranscriber {
    let events: AsyncStream<STTStreamEvent>

    private static let urlSession = URLSession(configuration: .default)

    private let eventContinuation: AsyncStream<STTStreamEvent>.Continuation
    private let configuration: OpenAITranscriptionConfiguration
    private let apiKey: String

    private var webSocket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    /// 送信順を保証する直列キュー（session.update → 音声チャンクの順序が入れ替わらないように、
    /// 送信ごとの Task 起動ではなく 1 本のループで送る）。
    private var sendQueue: AsyncStream<Data>.Continuation?
    private var partialTranscript = ""
    private var isStopped = false

    init(configuration: OpenAITranscriptionConfiguration = OpenAITranscriptionConfiguration(), apiKey: String) {
        self.configuration = configuration
        self.apiKey = apiKey
        (events, eventContinuation) = AsyncStream.makeStream(
            of: STTStreamEvent.self, bufferingPolicy: .unbounded)
    }

    func connect() {
        guard webSocket == nil, !isStopped else { return }
        var request = URLRequest(url: configuration.websocketURL)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let task = Self.urlSession.webSocketTask(with: request)
        webSocket = task
        task.resume()
        startSender(webSocket: task)

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
                        self.handle(RealtimeServerEvent.parse(text))
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
        guard let data = try? RealtimeClientEvent.inputAudioAppend(
            base64Audio: chunk.base64EncodedString()) else { return }
        sendQueue?.yield(data)
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        receiveTask?.cancel()
        sendTask?.cancel()
        receiveTask = nil
        sendTask = nil
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

    private func handleSocketClosed(_ error: Error) {
        guard !isStopped else { return }
        var detail = error.localizedDescription
        if let webSocket, webSocket.closeCode != .invalid {
            let reason = webSocket.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            detail += " (close=\(webSocket.closeCode.rawValue) \(reason))"
        }
        eventContinuation.yield(.connectionFailed("STT 接続が切れました: \(detail)"))
    }

    private func handle(_ event: RealtimeServerEvent) {
        switch event {
        case .sessionCreated:
            if let data = try? OpenAITranscriptionClientEvent.sessionUpdate(configuration: configuration) {
                sendQueue?.yield(data)
            }

        case .sessionUpdated:
            eventContinuation.yield(.ready)

        case .speechStarted:
            partialTranscript = ""
            eventContinuation.yield(.speechStarted)

        case .speechStopped:
            eventContinuation.yield(.speechStopped)

        case .userTranscriptDelta(let delta):
            partialTranscript += delta
            eventContinuation.yield(.partialTranscript(partialTranscript))

        case .userTranscriptCompleted(let transcript):
            partialTranscript = ""
            eventContinuation.yield(.finalTranscript(transcript))

        case .userTranscriptFailed(let message):
            partialTranscript = ""
            eventContinuation.yield(.transcriptFailed(message))

        case .serverError(let message, let ignorable):
            // STT が機能しない状態で会話を続けても仕方がないため、非 ignorable は致命扱いにする
            eventContinuation.yield(
                ignorable ? .notice(message) : .connectionFailed("STT API エラー: \(message)"))

        case .responseCreated, .assistantAudioDelta, .assistantTranscriptDelta,
             .assistantTranscriptDone, .responseDone, .ignored:
            // transcription セッションでは response 系イベントは来ない
            break
        }
    }
}
