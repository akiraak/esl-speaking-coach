import AVFAudio
import Foundation
import UIKit

/// 案 A2（クラウド STT + Claude + クラウド TTS）の VoiceSession 実装。
/// マイク → gpt-4o-transcribe（WebSocket） → Claude（SSE） → クラウド TTS（HTTP ストリーミング）を
/// ターン制で回す。会話相手は Claude のまま。
///
/// 発話終端・barge-in は STT セッションのサーバ VAD を使う。
///
/// 状態遷移:
///   listening --(サーバ VAD: speech_stopped)--> thinking --(STT 確定 → Claude → 初文 TTS 再生)--> speaking --> listening
///   speaking / thinking 中に speech_started が来たら barge-in（TTS 停止 + Claude キャンセル）で listening へ戻る。
///   STT 切断時は reconnecting（backoff 付き再接続）、割り込み・バックグラウンド遷移時は suspended を経由して復帰する。
///
/// 寿命: start〜stop の間は切断・割り込みから自力で復帰する。stop 後の再 start はできない（毎回作り直す）。
///
/// エラーの扱い:
///   - 致命的（キー未設定・マイク権限拒否・再接続 backoff 尽き等）→ .failure を流して stop()。
///     events が finish するので ViewModel 側は自動的にデタッチされる
///   - 回復可能（Claude ターン 1 回の失敗・TTS 1 文の失敗・STT 1 セグメントの失敗）→ .info 通知で継続
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
    private var reconnectTask: Task<Void, Never>?
    private var reconnectPolicy = ReconnectPolicy()
    private var observerTokens: [any NSObjectProtocol] = []
    private var metrics = TurnMetricsBuilder()
    private var hasStarted = false
    private var isStopped = false
    private var isMicStreaming = false
    private var isVoiceProcessingActive = true
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
            fail("OpenAI API キーが未設定です。.secrets/openai-api-key を用意して再インストールしてください。")
            return
        }
        _ = openAIKey
        if configuration.ttsProvider == .gemini {
            guard let geminiKey = geminiKeyProvider(), !geminiKey.isEmpty else {
                fail("Gemini API キーが未設定です。.secrets/gemini-api-key を用意して再インストールしてください。")
                return
            }
        }
        guard let claudeKey = claudeKeyProvider(), !claudeKey.isEmpty else {
            fail("Anthropic API キーが未設定です。設定画面から保存してください。")
            return
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
            fail("オーディオセッションの設定に失敗: \(error.localizedDescription)")
            return
        }
        #else
        guard await AVAudioApplication.requestRecordPermission() else {
            fail("マイクの使用が許可されていません。設定アプリから許可してください。")
            return
        }
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(
                .playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
            try audioSession.setActive(true)
        } catch {
            fail("オーディオセッションの設定に失敗: \(error.localizedDescription)")
            return
        }
        #endif

        guard !isStopped else { return }

        do {
            try speaker.prepare()
        } catch {
            fail("再生エンジンの起動に失敗: \(error.localizedDescription)")
            return
        }

        startSystemObservers()
        eventContinuation.yield(.info("STT へ接続中… (\(configuration.transcription.model))"))
        connectSTT()
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
        observerTokens.removeAll()
        sttEventTask?.cancel()
        claudeTask?.cancel()
        micStreamTask?.cancel()
        levelTask?.cancel()
        micWatchdogTask?.cancel()
        reconnectTask?.cancel()
        sttEventTask = nil
        claudeTask = nil
        micStreamTask = nil
        levelTask = nil
        micWatchdogTask = nil
        reconnectTask = nil
        transcriber?.stop()
        transcriber = nil
        speaker.shutdown()
        microphone.router.detachRaw()
        microphone.stop()
        // 会話中に奪っていたオーディオを他アプリ（音楽等）へ返す
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation)
        state = .idle
        eventContinuation.finish()
    }

    /// 復帰不能なエラー。failure を通知してセッションを終了する
    /// （events が finish することで ViewModel 側もデタッチされる）。
    private func fail(_ message: String) {
        eventContinuation.yield(.failure(message))
        stop()
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

    // MARK: - STT 接続・再接続

    private func connectSTT() {
        guard !isStopped else { return }
        guard let openAIKey = openAIKeyProvider(), !openAIKey.isEmpty else {
            fail("OpenAI API キーが未設定です。.secrets/openai-api-key を用意して再インストールしてください。")
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
        stt.connect()
    }

    /// STT 切断。セッションを殺さず backoff 付きで再接続する（Wi-Fi ⇔ LTE 切替やサーバ側打ち切り対策）。
    /// 認識途中のセグメントは失われるが、確定済みの pendingTurnText は再接続後に commit する。
    private func handleSTTConnectionLost(_ message: String) {
        guard !isStopped else { return }
        isUserSpeaking = false
        pendingSegments = 0
        sttEventTask?.cancel()
        sttEventTask = nil
        transcriber?.stop()
        transcriber = nil

        guard let delay = reconnectPolicy.nextDelay() else {
            fail("STT への再接続に失敗しました: \(message)")
            return
        }
        // Claude ターンが走っていなければ表示を reconnecting へ。走っていれば裏で静かにつなぎ直す
        if claudeTask == nil, state == .listening || state == .thinking {
            state = .reconnecting
        }
        eventContinuation.yield(.info(
            "STT 接続が切れました（\(message)）。\(String(format: "%.1f", delay)) 秒後に再接続します（\(reconnectPolicy.attempt) 回目）"))
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !self.isStopped, !Task.isCancelled else { return }
            self.reconnectTask = nil
            self.connectSTT()
        }
    }

    // MARK: - STT events

    private func handleSTT(_ event: STTStreamEvent) {
        switch event {
        case .ready:
            reconnectPolicy.reset()
            startMicrophoneStreaming()
            switch state {
            case .preparing:
                state = .listening
                eventContinuation.yield(.info(
                    "接続完了（STT: \(configuration.transcription.model), TTS: \(speaker.voiceDescription), LLM: \(client.parameters.model)）"))
            case .reconnecting:
                state = .listening
                eventContinuation.yield(.info("STT 再接続完了"))
                commitPendingTurnIfReady()
            default:
                // thinking / speaking 中に裏で再接続が完了した。ターン終了時に listening へ戻る
                eventContinuation.yield(.info("STT 再接続完了"))
            }

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
            handleSTTConnectionLost(message)
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

    private func startClaudeTurn(attempt: Int = 0) {
        guard let apiKey = claudeKeyProvider(), !apiKey.isEmpty else {
            fail("Anthropic API キーが未設定です。設定画面から保存してください。")
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
                self.handleClaudeTurnError(error, attempt: attempt, partialText: fullText)
            }
        }
    }

    /// Claude ターンの失敗はセッションを殺さない（回復可能エラー）。
    /// 何も出力される前の失敗は 1 回だけ自動リトライし、それでもだめなら listening に戻して
    /// もう一度話してもらう。途中まで出力があった場合はそこまでを履歴に残して打ち切る。
    private func handleClaudeTurnError(_ error: Error, attempt: Int, partialText: String) {
        guard !isStopped else { return }
        if partialText.isEmpty, attempt == 0 {
            eventContinuation.yield(.info(
                "応答の取得に失敗したためリトライします: \(error.localizedDescription)"))
            // リトライ待ちにも claudeTask を使う（barge-in の cancel 導線をそのまま効かせる）
            claudeTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, !self.isStopped, !Task.isCancelled else { return }
                self.claudeTask = nil
                // barge-in や suspend で状況が変わっていたら中止
                guard self.state == .thinking else { return }
                self.startClaudeTurn(attempt: 1)
            }
            return
        }
        finishAssistantTurn(fullText: partialText)
        if partialText.isEmpty {
            eventContinuation.yield(.info(
                "応答を取得できませんでした。もう一度話しかけてください: \(error.localizedDescription)"))
        } else {
            eventContinuation.yield(.info("応答が途中で終了しました: \(error.localizedDescription)"))
        }
        // 文が 1 つも積まれていなくても endStream で onTurnFinished が飛び listening に戻る
        speaker.endStream()
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

    // MARK: - 割り込み・バックグラウンド・経路変更

    /// AVAudioSession の割り込み・経路変更と、アプリのバックグラウンド遷移を監視する。
    /// UI 層にオーディオの知識を漏らさないため、セッション自身が NotificationCenter を購読する。
    private func startSystemObservers() {
        let center = NotificationCenter.default
        observerTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsValue = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated {
                self?.handleInterruption(typeValue: typeValue, optionsValue: optionsValue)
            }
        })
        observerTokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated { self?.handleRouteChange(reasonValue: reasonValue) }
        })
        observerTokens.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // メディアサービスのリセット後は AVAudioEngine の作り直しが必要。
            // 発生は稀なのでセッション再構築ではなく明示的なエラー終了にする（開始し直せば復帰できる）
            MainActor.assumeIsolated {
                self?.fail("オーディオサービスがリセットされました。会話を開始し直してください。")
            }
        })
        observerTokens.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspend(reason: "バックグラウンドへ移行しました") }
        })
        observerTokens.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        })
    }

    private func handleInterruption(typeValue: UInt?, optionsValue: UInt?) {
        guard let typeValue,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            suspend(reason: "オーディオ割り込み（電話・Siri 等）")
        case .ended:
            // shouldResume が無くても resume を試みる（失敗したら suspended のまま次の契機を待つ）
            _ = AVAudioSession.InterruptionOptions(rawValue: optionsValue ?? 0)
            resume()
        @unknown default:
            break
        }
    }

    private func handleRouteChange(reasonValue: UInt?) {
        guard let reasonValue,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        switch reason {
        case .oldDeviceUnavailable:
            restartAudioIO(reason: "出力デバイスが外れました")
        case .newDeviceAvailable:
            restartAudioIO(reason: "新しいオーディオデバイスが接続されました")
        default:
            break
        }
    }

    /// 電話・Siri 等の割り込みやバックグラウンド遷移で全 I/O を止める。
    /// 会話履歴は保持し、resume() で復帰する。
    private func suspend(reason: String) {
        guard hasStarted, !isStopped, state != .idle, state != .suspended else { return }
        claudeTask?.cancel()  // 途中までの応答は CancellationError 経由で履歴に残る
        claudeTask = nil
        speaker.stopNow()
        reconnectTask?.cancel()
        reconnectTask = nil
        sttEventTask?.cancel()
        sttEventTask = nil
        transcriber?.stop()
        transcriber = nil
        stopMicrophoneStreaming()
        isUserSpeaking = false
        pendingSegments = 0
        pendingTurnText = ""
        state = .suspended
        eventContinuation.yield(.info("一時停止しました（\(reason)）"))
    }

    /// suspend() からの復帰。オーディオセッションを再アクティベートし、エンジンと STT を立て直す。
    /// マイクは STT の ready 時に再起動される。
    private func resume() {
        guard hasStarted, !isStopped, state == .suspended else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // 通話が続いている等でまだ取り返せないケース。suspended のまま次の resume 契機を待つ
            eventContinuation.yield(.info(
                "オーディオセッションを再開できませんでした（次の機会に再試行）: \(error.localizedDescription)"))
            return
        }
        do {
            try speaker.prepare()
        } catch {
            fail("再生エンジンの再起動に失敗: \(error.localizedDescription)")
            return
        }
        state = .reconnecting
        reconnectPolicy.reset()
        eventContinuation.yield(.info("再開します。STT へ再接続中…"))
        connectSTT()
    }

    /// イヤホン抜き差し等の経路変更で AVAudioEngine が止まったときの入出力再起動。STT 接続は維持する。
    /// 再生中だった応答は打ち切る（barge-in と同じ導線で listening へ戻す）。
    private func restartAudioIO(reason: String) {
        guard hasStarted, !isStopped else { return }
        guard state != .idle, state != .preparing, state != .suspended else { return }
        let wasSpeaking = state == .speaking
        if wasSpeaking {
            claudeTask?.cancel()
            claudeTask = nil
            speaker.stopNow()
        }
        stopMicrophoneStreaming()
        do {
            try speaker.prepare()
        } catch {
            fail("再生エンジンの再起動に失敗: \(error.localizedDescription)")
            return
        }
        startMicrophoneStreaming()
        if wasSpeaking {
            state = .listening
        }
        eventContinuation.yield(.info("オーディオ経路が変わったため入出力を再起動しました（\(reason)）"))
    }

    // MARK: - Microphone

    /// 再入可能（起動済みなら何もしない）。初回接続・再接続・経路変更後の再起動から共通で呼ぶ。
    private func startMicrophoneStreaming() {
        #if targetEnvironment(simulator)
        return
        #else
        guard !isMicStreaming else { return }
        do {
            try microphone.start(voiceProcessing: isVoiceProcessingActive)
        } catch {
            fail("マイクの起動に失敗: \(error.localizedDescription)")
            return
        }
        isMicStreaming = true
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

    private func stopMicrophoneStreaming() {
        micStreamTask?.cancel()
        micStreamTask = nil
        micWatchdogTask?.cancel()
        micWatchdogTask = nil
        // levelTask は止めない: router.levels は 1 度しか消費できない AsyncStream のため、
        // suspend / resume をまたいで 1 本の購読を使い回す（マイク停止中はレベルが流れないだけ）
        microphone.router.detachRaw()
        microphone.stop()
        isMicStreaming = false
    }

    private func startLevelMonitor() {
        guard levelTask == nil else { return }
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
                    self.fail("マイクの再起動に失敗: \(error.localizedDescription)")
                    return
                }
                self.startMicWatchdog()
            } else {
                self.fail(
                    "マイクから音声バッファが届いていません。マイク権限と、他アプリがマイクを使っていないか確認してください")
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
