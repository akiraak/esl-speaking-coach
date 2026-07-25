import AVFAudio
import Foundation

/// 案 A2（クラウド STT + Claude + クラウド TTS）の VoiceSession 実装。
/// マイク → gpt-4o-transcribe（WebSocket） → Claude（SSE） → gpt-4o-mini-tts（HTTP ストリーミング）を
/// ターン制で回す。会話相手は Claude のまま。
///
/// 発話終端・barge-in は STT セッションのサーバ VAD を使う（旧案 A の無音タイマー + RMS を置換。
/// 案 B と同じ判定になるため Phase 4 のレイテンシ比較条件も揃う）。
///
/// 状態遷移:
///   listening --(サーバ VAD: speech_stopped)--> thinking --(STT 確定 → Claude → 初文 TTS 再生)--> speaking --> listening
///   speaking / thinking 中に speech_started が来たら barge-in（TTS 停止 + Claude キャンセル）で listening へ戻る。
///
/// インスタンスは使い捨て（start → stop で終了。再 start はできないので毎回作り直す）。
@MainActor
final class TurnBasedVoiceSession: VoiceSession {
    struct Configuration: Sendable {
        var transcription = OpenAITranscriptionConfiguration()
        /// 採用構成は Gemini TTS（2026-07-25 決定）。OpenAI TTS へは聞き比べ用に切替可
        var ttsProvider: TTSProvider = .gemini
        var openAITTS = OpenAITTSConfiguration()
        var geminiTTS = GeminiTTSConfiguration()
    }

    let events: AsyncStream<VoiceSessionEvent>

    private static let micFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)!

    private let eventContinuation: AsyncStream<VoiceSessionEvent>.Continuation
    private let configuration: Configuration
    private let client = ClaudeMessagesClient()
    private let claudeKeyProvider: @Sendable () -> String?
    private let openAIKeyProvider: @Sendable () -> String?
    private let geminiKeyProvider: @Sendable () -> String?
    private let microphone = MicrophoneCapture()
    private let speaker: CloudSentenceSpeaker

    private var state: VoiceSessionState = .idle {
        didSet { eventContinuation.yield(.stateChanged(state)) }
    }

    private var history: [ConversationMessage] = []
    private var transcriber: (any StreamingSpeechTranscriber)?
    private var sttEventTask: Task<Void, Never>?
    private var claudeTask: Task<Void, Never>?
    private var micStreamTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private var micWatchdogTask: Task<Void, Never>?
    private var metrics = TurnMetricsBuilder()
    private var hasStarted = false
    private var isStopped = false
    private var isVoiceProcessingActive = false
    /// サーバ VAD が発話中と判定している間 true
    private var isUserSpeaking = false
    /// speech_stopped 済みで確定テキスト待ちのセグメント数
    private var pendingSegments = 0
    /// まだ Claude に投げていない確定済みテキスト（短いポーズで複数セグメントに割れた発話を結合する）
    private var pendingTurnText = ""

    init(
        configuration: Configuration = Configuration(),
        claudeKeyProvider: @escaping @Sendable () -> String?,
        openAIKeyProvider: @escaping @Sendable () -> String?,
        geminiKeyProvider: @escaping @Sendable () -> String? = { nil }
    ) {
        self.configuration = configuration
        self.claudeKeyProvider = claudeKeyProvider
        self.openAIKeyProvider = openAIKeyProvider
        self.geminiKeyProvider = geminiKeyProvider
        switch configuration.ttsProvider {
        case .openAI:
            speaker = CloudSentenceSpeaker(
                client: OpenAITTSClient(configuration: configuration.openAITTS),
                apiKeyProvider: openAIKeyProvider)
        case .gemini:
            speaker = CloudSentenceSpeaker(
                client: GeminiTTSClient(configuration: configuration.geminiTTS),
                apiKeyProvider: geminiKeyProvider)
        }
        (events, eventContinuation) = AsyncStream.makeStream(
            of: VoiceSessionEvent.self, bufferingPolicy: .unbounded)

        speaker.onTurnAudioStarted = { [weak self] in self?.handleTurnAudioStarted() }
        speaker.onTurnFinished = { [weak self] in self?.handleTurnFinished() }
        speaker.onError = { [weak self] message in self?.eventContinuation.yield(.info(message)) }
    }

    // MARK: - VoiceSession

    func start() async {
        guard !hasStarted, !isStopped else { return }
        hasStarted = true
        state = .preparing

        guard let openAIKey = openAIKeyProvider(), !openAIKey.isEmpty else {
            eventContinuation.yield(.failure("OpenAI API キーが未設定です。.secrets/openai-api-key を用意して再インストールしてください。"))
            return
        }
        if configuration.ttsProvider == .gemini {
            guard let geminiKey = geminiKeyProvider(), !geminiKey.isEmpty else {
                eventContinuation.yield(.failure("Gemini API キーが未設定です。.secrets/gemini-api-key を用意して再インストールしてください。"))
                return
            }
        }

        #if targetEnvironment(simulator)
        // シミュレータでは音声入力ユニットの初期化が CoreAudio の RPC タイムアウトで abort するため
        // （旧 Phase 1 で確認済み）、マイクに触らずテキスト入力で Claude / TTS / STT 接続のみ検証する。
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
            try speaker.prepare()
        } catch {
            eventContinuation.yield(.failure("再生エンジンの起動に失敗: \(error.localizedDescription)"))
            return
        }

        let stt = OpenAITranscriptionStream(
            configuration: configuration.transcription, apiKey: openAIKey)
        transcriber = stt
        sttEventTask = Task { [weak self] in
            for await event in stt.events {
                guard let self, !self.isStopped else { return }
                self.handleSTT(event)
            }
        }
        eventContinuation.yield(.info("STT へ接続中… (\(configuration.transcription.model))"))
        stt.connect()
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        sttEventTask?.cancel()
        claudeTask?.cancel()
        micStreamTask?.cancel()
        levelTask?.cancel()
        micWatchdogTask?.cancel()
        sttEventTask = nil
        claudeTask = nil
        micStreamTask = nil
        levelTask = nil
        micWatchdogTask = nil
        transcriber?.stop()
        transcriber = nil
        speaker.shutdown()
        microphone.router.detachRaw()
        microphone.stop()
        state = .idle
        eventContinuation.finish()
    }

    #if DEBUG
    /// STT を経由せず user ターンを投入する（シミュレータでの Claude / TTS 検証用）。
    func submitTypedUserTurn(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, state == .listening, claudeTask == nil else { return }
        state = .thinking

        metrics = TurnMetricsBuilder()
        let now = Date()
        metrics.utteranceEndedAt = now
        metrics.committedAt = now
        metrics.transcriptFinalizedAt = now
        commitText(trimmed)
    }
    #endif

    // MARK: - STT events

    private func handleSTT(_ event: STTStreamEvent) {
        switch event {
        case .ready:
            guard state == .preparing else { return }
            startMicrophoneStreaming()
            state = .listening
            eventContinuation.yield(.info(
                "接続完了（STT: \(configuration.transcription.model), TTS: \(speaker.voiceDescription), LLM: \(client.parameters.model)）"))

        case .speechStarted:
            handleSpeechStarted()

        case .speechStopped:
            // サーバ VAD が発話終端を判定した。ここから応答音声の再生開始までが体感レイテンシ
            // （VAD の無音待ち自体は計測に含まれない。案 B と同じ条件）
            isUserSpeaking = false
            pendingSegments += 1
            metrics = TurnMetricsBuilder()
            let now = Date()
            metrics.utteranceEndedAt = now
            metrics.committedAt = now
            if state == .listening { state = .thinking }

        case .partialTranscript(let text):
            eventContinuation.yield(.userPartialTranscript(text))

        case .finalTranscript(let transcript):
            pendingSegments = max(0, pendingSegments - 1)
            metrics.transcriptFinalizedAt = Date()
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                pendingTurnText = pendingTurnText.isEmpty ? trimmed : pendingTurnText + " " + trimmed
            }
            commitPendingTurnIfReady()

        case .transcriptFailed(let message):
            pendingSegments = max(0, pendingSegments - 1)
            eventContinuation.yield(.info("認識に失敗したセグメントがあります: \(message)"))
            commitPendingTurnIfReady()

        case .notice(let message):
            eventContinuation.yield(.info("サーバ通知: \(message)"))

        case .connectionFailed(let message):
            eventContinuation.yield(.failure(message))
            stop()
        }
    }

    /// barge-in: サーバ VAD がユーザーの発話開始を検知した。応答の生成・再生中なら即座に止める。
    private func handleSpeechStarted() {
        isUserSpeaking = true
        if claudeTask != nil || state == .speaking {
            claudeTask?.cancel()
            claudeTask = nil
            speaker.stopNow()
            eventContinuation.yield(.info("割り込みを検知しました"))
        }
        if state != .listening { state = .listening }
    }

    /// 確定テキストが揃っていて、ユーザーが話しておらず、Claude ターンも走っていなければ投げる。
    private func commitPendingTurnIfReady() {
        guard !isUserSpeaking, pendingSegments == 0, claudeTask == nil else { return }
        let text = pendingTurnText
        pendingTurnText = ""
        guard !text.isEmpty else {
            // ノイズ等で VAD だけ発火して空だった。聞き取りへ戻す
            if state == .thinking { state = .listening }
            return
        }
        if state != .thinking { state = .thinking }
        commitText(text)
    }

    // MARK: - Turn commit → Claude

    private func commitText(_ text: String) {
        appendUserMessage(text)
        eventContinuation.yield(.userTurnCommitted(text))
        startClaudeTurn()
    }

    /// Anthropic API は同一ロールの連続ターンを想定しないため、
    /// barge-in 等で assistant 応答が空だった場合は直前の user ターンへ結合する。
    private func appendUserMessage(_ text: String) {
        if let last = history.last, last.role == .user {
            history[history.count - 1].text += "\n" + text
        } else {
            history.append(ConversationMessage(role: .user, text: text))
        }
    }

    private func startClaudeTurn() {
        guard let apiKey = claudeKeyProvider(), !apiKey.isEmpty else {
            eventContinuation.yield(.failure("Anthropic API キーが未設定です。設定画面から保存してください。"))
            state = .listening
            return
        }

        speaker.beginTurn()
        let stream = client.streamReply(
            apiKey: apiKey, system: CoachSystemPrompt.text, messages: history)

        claudeTask = Task { [weak self] in
            guard let self else { return }
            var chunker = SentenceChunker()
            var fullText = ""
            self.metrics.requestStartedAt = Date()

            do {
                for try await event in stream {
                    switch event {
                    case .textDelta(let delta):
                        if self.metrics.firstDeltaAt == nil {
                            self.metrics.firstDeltaAt = Date()
                        }
                        fullText += delta
                        self.eventContinuation.yield(.assistantTextDelta(delta))
                        for sentence in chunker.consume(delta) {
                            self.enqueueSentence(sentence)
                        }
                    case .messageStopped(let stopReason):
                        if let stopReason, stopReason != "end_turn" {
                            self.eventContinuation.yield(.info("stop_reason: \(stopReason)"))
                        }
                    }
                }
                if let rest = chunker.flush() {
                    self.enqueueSentence(rest)
                }
                self.claudeTask = nil
                self.finishAssistantTurn(fullText: fullText)
                self.speaker.endStream()
            } catch is CancellationError {
                self.finishAssistantTurn(fullText: fullText)
            } catch {
                if Task.isCancelled {
                    self.finishAssistantTurn(fullText: fullText)
                    return
                }
                self.claudeTask = nil
                self.finishAssistantTurn(fullText: fullText)
                self.eventContinuation.yield(.failure(error.localizedDescription))
                // 文が 1 つも積まれていなくても endStream で onTurnFinished が飛び listening に戻る
                self.speaker.endStream()
            }
        }
    }

    private func finishAssistantTurn(fullText: String) {
        guard !fullText.isEmpty else { return }
        history.append(ConversationMessage(role: .assistant, text: fullText))
        eventContinuation.yield(.assistantTurnCompleted(fullText))
    }

    private func enqueueSentence(_ sentence: String) {
        if metrics.firstSentenceAt == nil {
            metrics.firstSentenceAt = Date()
        }
        speaker.enqueue(sentence)
    }

    // MARK: - Playback callbacks

    private func handleTurnAudioStarted() {
        metrics.audioStartedAt = Date()
        state = .speaking
        eventContinuation.yield(.turnMetrics(metrics.build()))
    }

    private func handleTurnFinished() {
        guard state == .thinking || state == .speaking else { return }
        state = .listening
        // AI の発話中に確定した user セグメントが残っていれば次のターンを始める
        commitPendingTurnIfReady()
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
                self.transcriber?.sendAudio(chunk)
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
                self.eventContinuation.yield(.micLevel(level))
            }
        }
    }

    /// マイクからバッファが届いているか監視する（案 B と同じ既知問題への対処）。
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

/// ターン内の計測タイムスタンプ。build() でミリ秒差分に変換する。
struct TurnMetricsBuilder {
    var utteranceEndedAt: Date?
    var committedAt: Date?
    var transcriptFinalizedAt: Date?
    var requestStartedAt: Date?
    var firstDeltaAt: Date?
    var firstSentenceAt: Date?
    var audioStartedAt: Date?

    func build() -> TurnMetrics {
        TurnMetrics(
            endpointWaitMs: ms(from: utteranceEndedAt, to: committedAt),
            sttFinalizeMs: ms(from: committedAt, to: transcriptFinalizedAt),
            ttftMs: ms(from: requestStartedAt, to: firstDeltaAt),
            firstSentenceMs: ms(from: firstDeltaAt, to: firstSentenceAt),
            speakStartMs: ms(from: firstSentenceAt, to: audioStartedAt),
            pipelineTotalMs: ms(from: committedAt, to: audioStartedAt),
            perceivedTotalMs: ms(from: utteranceEndedAt, to: audioStartedAt)
        )
    }

    private func ms(from start: Date?, to end: Date?) -> Double? {
        guard let start, let end else { return nil }
        return end.timeIntervalSince(start) * 1000
    }
}
