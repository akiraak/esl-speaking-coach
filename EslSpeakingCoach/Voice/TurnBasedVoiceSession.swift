import AVFAudio
import Foundation

/// 案 A（iOS 内蔵音声 + Claude ストリーミング）の VoiceSession 実装。
/// マイク → SpeechTranscriber → Claude(SSE) → AVSpeechSynthesizer をターン制で回す。
///
/// 状態遷移:
///   listening --(無音 silenceWindow 経過)--> thinking --(TTS 開始)--> speaking --> listening
///   speaking 中にマイク RMS がしきい値を連続で超えたら barge-in として listening へ戻る。
///
/// インスタンスは使い捨て（start → stop で終了。再 start はできないので毎回作り直す）。
@MainActor
final class TurnBasedVoiceSession: VoiceSession {
    struct Configuration: Sendable {
        var locale = Locale(identifier: "en_US")
        /// 発話終端とみなす無音時間（最後の認識更新からの経過）
        var silenceWindow: TimeInterval = 1.0
        /// barge-in 判定の RMS しきい値（実機でチューニングする。UI にレベルを出している）
        var bargeInLevelThreshold: Float = 0.05
        /// barge-in 判定に必要な連続バッファ数（1 バッファ ≒ 43ms @48kHz/2048frame）
        var bargeInStreak = 4
        /// Voice Processing I/O（エコーキャンセル）。barge-in には実質必須
        var voiceProcessing = true
    }

    let events: AsyncStream<VoiceSessionEvent>

    private let eventContinuation: AsyncStream<VoiceSessionEvent>.Continuation
    private let configuration: Configuration
    private let client = ClaudeMessagesClient()
    private let apiKeyProvider: @Sendable () -> String?
    private let microphone = MicrophoneCapture()
    private let speaker = SentenceSpeaker()

    private var state: VoiceSessionState = .idle {
        didSet { eventContinuation.yield(.stateChanged(state)) }
    }

    private var history: [ConversationMessage] = []
    private var resolvedLocale: Locale?
    private var transcriber: UtteranceTranscriber?
    private var claudeTask: Task<Void, Never>?
    private var silenceTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private var currentTranscript = ""
    private var lastTranscriptUpdateAt: Date?
    private var loudStreak = 0
    private var metrics = TurnMetricsBuilder()
    private var hasStarted = false
    private var isStopped = false
    /// STT モデルが用意できなかった（シミュレータの既知の制限など）。
    /// この場合は聞き取りなしの listening になり、DEBUG のテキスト入力だけでターンを回せる。
    private var isSTTUnavailable = false
    /// Voice Processing（エコーキャンセル）が実際に有効か。barge-in はこれが前提
    /// （VP なしだと TTS のスピーカー出力を自分で拾って誤検知するため無効化する）。
    private var isVoiceProcessingActive = false
    private var micWatchdogTask: Task<Void, Never>?
    private var modelDownloadBucket = -1

    /// 25% 刻みでダウンロード進捗を通知する（毎秒出すとログが埋まるため）。
    private func reportModelDownloadProgress(_ fraction: Double) {
        let bucket = Int(fraction * 4)
        guard bucket > modelDownloadBucket else { return }
        modelDownloadBucket = bucket
        eventContinuation.yield(.info("音声認識モデルをダウンロード中… \(Int(fraction * 100))%"))
    }

    init(configuration: Configuration = Configuration(), apiKeyProvider: @escaping @Sendable () -> String?) {
        self.configuration = configuration
        self.apiKeyProvider = apiKeyProvider
        (events, eventContinuation) = AsyncStream.makeStream(
            of: VoiceSessionEvent.self, bufferingPolicy: .unbounded)

        speaker.onTurnAudioStarted = { [weak self] in self?.handleTurnAudioStarted() }
        speaker.onTurnFinished = { [weak self] in self?.handleTurnFinished() }
    }

    // MARK: - VoiceSession

    func start() async {
        guard !hasStarted, !isStopped else { return }
        hasStarted = true
        state = .preparing

        #if targetEnvironment(simulator)
        // シミュレータでは (1) STT モデル資産が取得できない (2) 音声入力ユニットの初期化が
        // CoreAudio の RPC タイムアウトで abort する（アプリ側で捕捉不能）ため、
        // マイクに一切触らず、DEBUG のテキスト入力で Claude / TTS / 状態機械のみ検証する。
        isSTTUnavailable = true
        eventContinuation.yield(.info("シミュレータのためマイク・音声認識は無効です。テキスト入力で検証できます（音声パスは実機で確認）"))
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

        do {
            eventContinuation.yield(.info("音声認識モデルを確認中…（初回のみダウンロードが走ります）"))
            resolvedLocale = try await UtteranceTranscriber.ensureModelInstalled(
                locale: configuration.locale
            ) { [weak self] fraction in
                self?.reportModelDownloadProgress(fraction)
            }
        } catch {
            // モデルが用意できなくても聞き取りなしで続行し、Claude / TTS はテキスト入力で検証できるようにする
            isSTTUnavailable = true
            eventContinuation.yield(.failure("音声認識モデルの準備に失敗: \(error.localizedDescription)"))
            eventContinuation.yield(.info("聞き取りなしで続行します（テキスト入力のみ）"))
        }

        guard !isStopped else { return }

        do {
            try microphone.start(voiceProcessing: configuration.voiceProcessing)
            isVoiceProcessingActive = configuration.voiceProcessing
        } catch {
            eventContinuation.yield(.failure("マイクの起動に失敗: \(error.localizedDescription)"))
            return
        }

        eventContinuation.yield(.info("マイク起動: \(microphone.inputFormatDescription)"))
        startLevelMonitor()
        startMicWatchdog()
        #endif

        eventContinuation.yield(.info("読み上げ音声: \(speaker.voiceDescription)"))
        await enterListening()
    }

    /// マイクからバッファが届いているか監視する。
    /// Voice Processing 有効時に入力専用エンジンが無音になる端末があるため、
    /// 2 秒間バッファゼロなら VP を切って再起動する（その場合 barge-in は無効になる）。
    private func startMicWatchdog() {
        micWatchdogTask?.cancel()
        micWatchdogTask = Task { [weak self] in
            guard let self else { return }
            let baseline = self.microphone.router.bufferCount
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, !self.isStopped else { return }
            let received = self.microphone.router.bufferCount - baseline
            guard received == 0 else { return }

            if self.isVoiceProcessingActive {
                self.eventContinuation.yield(.info(
                    "マイクからバッファが届かないため Voice Processing を無効化して再起動します（barge-in は使えません）"))
                self.isVoiceProcessingActive = false
                self.microphone.stop()
                do {
                    try self.microphone.start(voiceProcessing: false)
                    self.eventContinuation.yield(.info("マイク再起動: \(self.microphone.inputFormatDescription)"))
                } catch {
                    self.eventContinuation.yield(.failure("マイクの再起動に失敗: \(error.localizedDescription)"))
                    return
                }
                if let transcriber = self.transcriber {
                    self.microphone.router.attach(
                        continuation: transcriber.inputContinuation,
                        format: transcriber.analyzerFormat)
                }
                self.startMicWatchdog()
            } else {
                self.eventContinuation.yield(.failure(
                    "マイクから音声バッファが届いていません。マイク権限と、他アプリがマイクを使っていないか確認してください"))
            }
        }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        micWatchdogTask?.cancel()
        micWatchdogTask = nil
        silenceTask?.cancel()
        levelTask?.cancel()
        claudeTask?.cancel()
        silenceTask = nil
        levelTask = nil
        claudeTask = nil
        speaker.stopNow()
        transcriber?.cancel()
        transcriber = nil
        microphone.router.detach()
        microphone.stop()
        state = .idle
        eventContinuation.finish()
    }

    // MARK: - Listening

    private func enterListening() async {
        guard !isStopped else { return }
        currentTranscript = ""
        lastTranscriptUpdateAt = nil
        loudStreak = 0

        if isSTTUnavailable {
            state = .listening
            return
        }

        do {
            let locale = resolvedLocale ?? configuration.locale
            let newTranscriber = try await UtteranceTranscriber(locale: locale)
            newTranscriber.onUpdate = { [weak self] text in
                self?.handleTranscriptUpdate(text)
            }
            microphone.router.attach(
                continuation: newTranscriber.inputContinuation,
                format: newTranscriber.analyzerFormat)
            transcriber = newTranscriber
            state = .listening
            startSilenceWatcher()
        } catch {
            eventContinuation.yield(.failure("音声認識の開始に失敗: \(error.localizedDescription)"))
            stop()
        }
    }

    private func handleTranscriptUpdate(_ text: String) {
        guard state == .listening, text != currentTranscript else { return }
        currentTranscript = text
        lastTranscriptUpdateAt = Date()
        eventContinuation.yield(.userPartialTranscript(text))
    }

    private func startSilenceWatcher() {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                guard self.state == .listening,
                      let lastUpdate = self.lastTranscriptUpdateAt,
                      !self.currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      Date().timeIntervalSince(lastUpdate) >= self.configuration.silenceWindow
                else { continue }
                await self.commitUserTurn()
                return
            }
        }
    }

    // MARK: - Turn commit → Claude

    private func commitUserTurn() async {
        guard state == .listening, let transcriber else { return }
        state = .thinking
        microphone.router.detach()

        metrics = TurnMetricsBuilder()
        metrics.utteranceEndedAt = lastTranscriptUpdateAt
        metrics.committedAt = Date()

        var text: String
        do {
            text = try await transcriber.finishAndCollect()
        } catch {
            text = currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        self.transcriber = nil
        metrics.transcriptFinalizedAt = Date()

        guard !text.isEmpty else {
            await enterListening()
            return
        }

        commitText(text)
    }

    private func commitText(_ text: String) {
        appendUserMessage(text)
        eventContinuation.yield(.userTurnCommitted(text))
        startClaudeTurn()
    }

    #if DEBUG
    /// STT を経由せず user ターンを投入する（シミュレータでの Claude / TTS 検証用）。
    func submitTypedUserTurn(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, state == .listening else { return }
        state = .thinking
        microphone.router.detach()
        silenceTask?.cancel()
        transcriber?.cancel()
        transcriber = nil

        metrics = TurnMetricsBuilder()
        let now = Date()
        metrics.utteranceEndedAt = now
        metrics.committedAt = now
        metrics.transcriptFinalizedAt = now
        commitText(trimmed)
    }
    #endif

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
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            eventContinuation.yield(.failure("API キーが未設定です。設定画面から保存してください。"))
            Task { await self.enterListening() }
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
                self.finishAssistantTurn(fullText: fullText)
                self.speaker.endStream()
            } catch is CancellationError {
                self.finishAssistantTurn(fullText: fullText)
            } catch {
                if Task.isCancelled {
                    self.finishAssistantTurn(fullText: fullText)
                    return
                }
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

    // MARK: - Speaking / barge-in

    private func handleTurnAudioStarted() {
        metrics.audioStartedAt = Date()
        state = .speaking
        eventContinuation.yield(.turnMetrics(metrics.build()))
    }

    private func handleTurnFinished() {
        guard state == .thinking || state == .speaking else { return }
        Task { await self.enterListening() }
    }

    private func startLevelMonitor() {
        levelTask?.cancel()
        levelTask = Task { [weak self] in
            guard let levels = self?.microphone.router.levels else { return }
            for await level in levels {
                guard let self, !Task.isCancelled else { return }
                self.eventContinuation.yield(.micLevel(level))
                if self.state == .speaking, self.isVoiceProcessingActive,
                   level >= self.configuration.bargeInLevelThreshold {
                    self.loudStreak += 1
                    if self.loudStreak >= self.configuration.bargeInStreak {
                        self.loudStreak = 0
                        await self.handleBargeIn()
                    }
                } else {
                    self.loudStreak = 0
                }
            }
        }
    }

    private func handleBargeIn() async {
        guard state == .speaking else { return }
        claudeTask?.cancel()
        claudeTask = nil
        speaker.stopNow()
        eventContinuation.yield(.info("割り込みを検知しました"))
        await enterListening()
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
