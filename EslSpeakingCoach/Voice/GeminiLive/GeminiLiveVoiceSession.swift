import AVFAudio
import Foundation

/// 案 C（Gemini Live speech-to-speech）の VoiceSession 実装。
/// マイクの PCM16 16kHz を WebSocket で送り続け、VAD・発話終端・barge-in はサーバ側に任せる。
/// 音声応答（24kHz）は RealtimeAudioPlayer で再生し、入出力の transcript を
/// プロバイダ非依存の履歴（ConversationMessage）として保存する。
///
/// OpenAI Realtime との構造上の違い:
/// - 発話終端（speech_stopped 相当）のサーバイベントが存在しない。レイテンシ計測の起点は
///   マイク RMS から推定した「最後に声があった時刻」を使う（体感値は推定値扱い）
/// - 応答開始（response.created 相当）のイベントもないため、最初の音声デルタで応答開始とみなす
/// - barge-in は serverContent.interrupted で通知される（クライアントから cancel を送る必要はない）
///
/// インスタンスは使い捨て（start → stop で終了。再 start はできないので毎回作り直す）。
@MainActor
final class GeminiLiveVoiceSession: VoiceSession {
    let events: AsyncStream<VoiceSessionEvent>

    private static let urlSession = URLSession(configuration: .default)
    private static let micFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(GeminiLiveConfiguration.inputSampleRate),
        channels: 1, interleaved: true)!
    /// この RMS を超えたら「声がある」とみなす（発話終端の推定用。barge-in には使わない）
    private static let voiceActivityThreshold: Float = 0.02

    private let eventContinuation: AsyncStream<VoiceSessionEvent>.Continuation
    private let configuration: GeminiLiveConfiguration
    private let apiKeyProvider: @Sendable () -> String?
    private let microphone = MicrophoneCapture()
    private let player = RealtimeAudioPlayer()

    private var webSocket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var micStreamTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private var micWatchdogTask: Task<Void, Never>?

    private var state: VoiceSessionState = .idle {
        didSet { eventContinuation.yield(.stateChanged(state)) }
    }

    private var history: [ConversationMessage] = []
    private var userPartialTranscript = ""
    /// 進行中応答の transcript 累積。barge-in 時は「そこまで」を履歴に残す
    /// （実際に聞こえた位置と多少ずれ得るが、スパイクでは許容する）。
    private var assistantTranscript = ""
    private var isResponseActive = false
    private var metrics = TurnMetricsBuilder()
    /// マイク RMS がしきい値を超えた最後の時刻（発話終端の推定に使う）
    private var lastVoiceActivityAt: Date?
    private var hasStarted = false
    private var isStopped = false
    private var isVoiceProcessingActive = false

    init(
        configuration: GeminiLiveConfiguration = GeminiLiveConfiguration(),
        apiKeyProvider: @escaping @Sendable () -> String?
    ) {
        self.configuration = configuration
        self.apiKeyProvider = apiKeyProvider
        (events, eventContinuation) = AsyncStream.makeStream(
            of: VoiceSessionEvent.self, bufferingPolicy: .unbounded)

        player.onTurnAudioStarted = { [weak self] in self?.handleTurnAudioStarted() }
        player.onTurnFinished = { [weak self] in self?.handleTurnFinished() }
    }

    // MARK: - VoiceSession

    func start() async {
        guard !hasStarted, !isStopped else { return }
        hasStarted = true
        state = .preparing

        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            eventContinuation.yield(.failure("Gemini API キーが未設定です。.secrets/gemini-api-key を用意して再インストールしてください。"))
            return
        }

        #if targetEnvironment(simulator)
        // シミュレータでは音声入力ユニットの初期化が CoreAudio の RPC タイムアウトで abort するため
        // （旧 Phase 1 で確認済み）、マイクに触らずテキスト入力で WebSocket / 再生のみ検証する。
        eventContinuation.yield(.info("シミュレータのためマイクは無効です。テキスト入力で検証できます（音声パスは実機で確認）"))
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default)
            try audioSession.setActive(true)
        } catch {
            eventContinuation.yield(.failure("オーディオセッションの設定に失敗: \(error.localizedDescription)"))
            return
        }
        #else
        guard await AVAudioApplication.requestRecordPermission() else {
            eventContinuation.yield(.failure("マイクの使用が許可されていません。設定アプリから許可してください。"))
            return
        }
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(
                .playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
            try audioSession.setActive(true)
        } catch {
            eventContinuation.yield(.failure("オーディオセッションの設定に失敗: \(error.localizedDescription)"))
            return
        }
        #endif

        guard !isStopped else { return }

        do {
            try player.prepare()
        } catch {
            eventContinuation.yield(.failure("再生エンジンの起動に失敗: \(error.localizedDescription)"))
            return
        }

        connect(apiKey: apiKey)
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        receiveTask?.cancel()
        micStreamTask?.cancel()
        levelTask?.cancel()
        micWatchdogTask?.cancel()
        receiveTask = nil
        micStreamTask = nil
        levelTask = nil
        micWatchdogTask = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        microphone.router.detachRaw()
        microphone.stop()
        player.shutdown()
        state = .idle
        eventContinuation.finish()
    }

    #if DEBUG
    /// マイクを経由せず user ターンを投入する（シミュレータでの検証用）。
    func submitTypedUserTurn(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, state == .listening else { return }
        state = .thinking

        metrics = TurnMetricsBuilder()
        let now = Date()
        metrics.utteranceEndedAt = now
        metrics.committedAt = now
        metrics.transcriptFinalizedAt = now
        metrics.requestStartedAt = now

        appendUserMessage(trimmed)
        eventContinuation.yield(.userTurnCommitted(trimmed))
        send { try GeminiLiveClientEvent.userTextTurn(trimmed) }
    }
    #endif

    // MARK: - WebSocket

    private func connect(apiKey: String) {
        guard let url = configuration.websocketURL(apiKey: apiKey) else {
            eventContinuation.yield(.failure("Gemini API キーから接続 URL を作れませんでした"))
            return
        }
        let task = Self.urlSession.webSocketTask(with: url)
        webSocket = task
        task.resume()
        eventContinuation.yield(.info("Gemini Live API へ接続中… (\(configuration.model))"))
        // 最初のメッセージは必ず setup（ハンドシェイク完了前の send はキューされる）
        send { [configuration] in try GeminiLiveClientEvent.setup(configuration: configuration) }

        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let socket = self?.webSocket else { return }
                do {
                    let message = try await socket.receive()
                    guard let self, !self.isStopped else { return }
                    // Live API はテキスト・バイナリ両方のフレームで JSON を送ってくる
                    let text: String?
                    switch message {
                    case .string(let string): text = string
                    case .data(let data): text = String(data: data, encoding: .utf8)
                    @unknown default: text = nil
                    }
                    if let text {
                        for event in GeminiLiveServerEvent.parse(text) {
                            self.handle(event)
                        }
                    }
                } catch {
                    self?.handleSocketClosed(error)
                    return
                }
            }
        }
    }

    /// JSON 生成 → WebSocket 送信。失敗はイベントで通知する（audio chunk の高頻度失敗は接続断で拾う）。
    private func send(_ makeEvent: @escaping @Sendable () throws -> Data) {
        guard let webSocket, !isStopped else { return }
        Task {
            do {
                let data = try makeEvent()
                guard let text = String(data: data, encoding: .utf8) else { return }
                try await webSocket.send(.string(text))
            } catch {
                guard !self.isStopped else { return }
                self.eventContinuation.yield(.failure("送信に失敗: \(error.localizedDescription)"))
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
        eventContinuation.yield(.failure("Gemini Live 接続が切れました: \(detail)"))
        stop()
    }

    // MARK: - Server events

    private func handle(_ event: GeminiLiveServerEvent) {
        switch event {
        case .setupComplete:
            guard state == .preparing else { return }
            startMicrophoneStreaming()
            state = .listening
            eventContinuation.yield(.info("接続完了（voice: \(configuration.voice), transcript: 入出力とも有効）"))

        case .userTranscriptDelta(let fragment):
            userPartialTranscript += fragment
            eventContinuation.yield(.userPartialTranscript(userPartialTranscript))

        case .assistantAudioDelta(let audio):
            beginResponseIfNeeded()
            if metrics.firstDeltaAt == nil {
                metrics.firstDeltaAt = Date()
            }
            player.enqueue(pcm16Data: audio)

        case .assistantTranscriptDelta(let fragment):
            beginResponseIfNeeded()
            assistantTranscript += fragment
            eventContinuation.yield(.assistantTextDelta(fragment))

        case .interrupted:
            handleInterrupted()

        case .generationComplete:
            break

        case .turnComplete:
            guard isResponseActive else { return }
            isResponseActive = false
            finishAssistantTurn()
            player.endStream()

        case .goAway(let timeLeft):
            eventContinuation.yield(.info("サーバが接続終了を予告しました（残り \(timeLeft)）。会話を終了して再開してください"))

        case .ignored:
            break
        }
    }

    /// 応答開始のサーバイベントが無いため、最初の音声 / transcript デルタで応答開始とみなす。
    /// このタイミングで、溜まっていたユーザー発話の transcript を user ターンとして確定する。
    private func beginResponseIfNeeded() {
        guard !isResponseActive else { return }
        isResponseActive = true
        assistantTranscript = ""
        player.beginTurn()

        // 音声起点のターンでは speech_stopped 相当が無いので、RMS から推定した発話終端を計測起点にする。
        // （requestStartedAt が入っているのはテキスト投入ターン。その場合は submit 時の値を使う）
        if metrics.requestStartedAt == nil {
            var fresh = TurnMetricsBuilder()
            let estimatedEnd = lastVoiceActivityAt ?? Date()
            fresh.utteranceEndedAt = estimatedEnd
            fresh.committedAt = estimatedEnd
            fresh.requestStartedAt = estimatedEnd
            metrics = fresh
        }
        if state == .listening {
            state = .thinking
        }
        commitUserTranscriptIfAny()
    }

    private func commitUserTranscriptIfAny() {
        let text = userPartialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        userPartialTranscript = ""
        guard !text.isEmpty else { return }
        metrics.transcriptFinalizedAt = Date()
        appendUserMessage(text)
        eventContinuation.yield(.userTurnCommitted(text))
    }

    /// barge-in: サーバ VAD がユーザーの発話開始を検知して応答を打ち切った。
    /// サーバ側は生成を止めているので、クライアントは再生を止めて履歴を確定するだけでよい。
    private func handleInterrupted() {
        guard state == .speaking || isResponseActive else { return }
        player.stopNow()
        isResponseActive = false
        finishAssistantTurn()
        metrics = TurnMetricsBuilder()
        eventContinuation.yield(.info("割り込みを検知しました"))
        state = .listening
    }

    private func finishAssistantTurn() {
        let text = assistantTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        assistantTranscript = ""
        guard !text.isEmpty else { return }
        history.append(ConversationMessage(role: .assistant, text: text))
        eventContinuation.yield(.assistantTurnCompleted(text))
    }

    /// 連続する user ターンは直前へ結合する（barge-in で assistant 応答が空だったケース）。
    private func appendUserMessage(_ text: String) {
        if let last = history.last, last.role == .user {
            history[history.count - 1].text += "\n" + text
        } else {
            history.append(ConversationMessage(role: .user, text: text))
        }
    }

    // MARK: - Playback callbacks

    private func handleTurnAudioStarted() {
        metrics.audioStartedAt = Date()
        state = .speaking
        eventContinuation.yield(.turnMetrics(metrics.build()))
        metrics = TurnMetricsBuilder()
    }

    private func handleTurnFinished() {
        guard state == .speaking else { return }
        state = .listening
    }

    // MARK: - Microphone

    private func startMicrophoneStreaming() {
        #if targetEnvironment(simulator)
        return
        #else
        do {
            try microphone.start(voiceProcessing: true)
            isVoiceProcessingActive = true
        } catch {
            eventContinuation.yield(.failure("マイクの起動に失敗: \(error.localizedDescription)"))
            return
        }
        eventContinuation.yield(.info("マイク起動: \(microphone.inputFormatDescription)"))

        let (stream, continuation) = AsyncStream.makeStream(
            of: Data.self, bufferingPolicy: .unbounded)
        microphone.router.attachRawPCM16(format: Self.micFormat, continuation: continuation)

        micStreamTask = Task { [weak self] in
            for await chunk in stream {
                guard let self, !self.isStopped, !Task.isCancelled else { return }
                self.send { try GeminiLiveClientEvent.audioChunk(base64Audio: chunk.base64EncodedString()) }
            }
        }
        startLevelMonitor()
        startMicWatchdog()
        #endif
    }

    private func startLevelMonitor() {
        levelTask?.cancel()
        levelTask = Task { [weak self] in
            guard let levels = self?.microphone.router.levels else { return }
            for await level in levels {
                guard let self, !Task.isCancelled else { return }
                // 発話終端の推定: 聞き取り中に声があった最後の時刻を覚えておく
                if level > Self.voiceActivityThreshold, self.state == .listening {
                    self.lastVoiceActivityAt = Date()
                }
                self.eventContinuation.yield(.micLevel(level))
            }
        }
    }

    /// マイクからバッファが届いているか監視する（RealtimeVoiceSession と同じ既知問題への対処）。
    /// Voice Processing 有効時に入力が無音になる端末があるため、2 秒間ゼロなら VP を切って再起動する。
    /// VP なしはエコーキャンセルが効かず、AI の再生音でサーバ VAD が誤発火し得る点に注意。
    private func startMicWatchdog() {
        micWatchdogTask?.cancel()
        micWatchdogTask = Task { [weak self] in
            guard let self else { return }
            let baseline = self.microphone.router.bufferCount
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, !self.isStopped else { return }
            guard self.microphone.router.bufferCount == baseline else { return }

            if self.isVoiceProcessingActive {
                self.eventContinuation.yield(.info(
                    "マイクからバッファが届かないため Voice Processing を無効化して再起動します（エコーで誤検知の可能性あり）"))
                self.isVoiceProcessingActive = false
                self.microphone.stop()
                do {
                    try self.microphone.start(voiceProcessing: false)
                    self.eventContinuation.yield(.info("マイク再起動: \(self.microphone.inputFormatDescription)"))
                } catch {
                    self.eventContinuation.yield(.failure("マイクの再起動に失敗: \(error.localizedDescription)"))
                    return
                }
                self.startMicWatchdog()
            } else {
                self.eventContinuation.yield(.failure(
                    "マイクから音声バッファが届いていません。マイク権限と、他アプリがマイクを使っていないか確認してください"))
            }
        }
    }
}
