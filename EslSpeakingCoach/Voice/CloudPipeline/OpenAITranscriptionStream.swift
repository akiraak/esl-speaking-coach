import Foundation

/// gpt-4o-transcribe の WebSocket ストリーミング実装（OpenAI Realtime API の transcription セッション）。
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
    private var pingTask: Task<Void, Never>?
    /// 送信順を保証する直列キュー（session.update → 音声チャンクの順序が入れ替わらないように、
    /// 送信ごとの Task 起動ではなく 1 本のループで送る）。
    private var sendQueue: AsyncStream<Data>.Continuation?
    private var partialTranscript = ""
    private var isStopped = false
    /// 切断は 1 回だけ通知する（ping 失敗と receive 失敗が両方検知したときの二重通知防止）。
    private var didReportClose = false

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
                        self.handle(OpenAITranscriptionServerEvent.parse(text))
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
        guard let data = try? OpenAITranscriptionClientEvent.inputAudioAppend(
            base64Audio: chunk.base64EncodedString()) else { return }
        sendQueue?.yield(data)
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
    /// ping が返らなければ切断扱いにして connectionFailed へ流す（再接続はセッション側が行う）。
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

    private func handle(_ event: OpenAITranscriptionServerEvent) {
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
            if ignorable {
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
