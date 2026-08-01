import AVFAudio
import Foundation

/// チャット欄の AI 吹き出しタップによる再読み上げ（docs/plans/utterance-replay.md）。
/// セッション外でのみ使う（セッション中は TurnBasedVoiceSession が AVAudioSession と
/// AVAudioEngine を占有している）。
///
/// 再生の 2 経路:
/// 1. 保存済みの音声キャッシュ（直前セッション分）があればファイル再生（即時・無料・オフライン可）
/// 2. 無ければ TTS で再生成して使い捨てる（SentenceChunker で文分割 →
///    CloudSentenceSpeaker の文単位ストリーミング。保存はしない）
///
/// AVAudioSession はセッション（playAndRecord / voiceChat）と別プロファイルの `.playback` を
/// 再生開始時に取り、完了 / 停止時に解放する。マイクを使わないため AudioRoutePolicy や
/// `.speaker` オーバーライドは適用しない（経路は OS の既定ルーティングに任せる）。
@MainActor
final class UtteranceReplayer {
    /// 再生が最後まで終わった（停止・切り替えでは呼ばない）。
    var onFinished: (() -> Void)?
    /// 再生成の TTS 利用量（料金記録用。ファイル再生は無料なので流れない）。
    var onUsage: ((AIUsageEvent) -> Void)?
    /// キー未設定・取得失敗など（タイムラインには出さず一時アラートにする想定）。
    var onError: ((String) -> Void)?

    private(set) var playingUtteranceID: UUID?

    private let cache: UtteranceAudioCache
    private let ttsConfiguration: SentenceTTSClientFactory.Configuration
    private let player: StreamingAudioPlayer
    private let speaker: CloudSentenceSpeaker
    private let apiKeyProvider: @Sendable () -> String?

    init(
        ttsConfiguration: SentenceTTSClientFactory.Configuration,
        apiKeyProvider: @escaping @Sendable () -> String?,
        cache: UtteranceAudioCache = .default
    ) {
        self.cache = cache
        self.ttsConfiguration = ttsConfiguration
        self.apiKeyProvider = apiKeyProvider
        let player = StreamingAudioPlayer()
        self.player = player
        // ファイル再生と再生成でエンジンを共有する。player のコールバックは speaker が
        // 束ねて転送するので、両経路とも speaker 側の closure で受ける
        self.speaker = CloudSentenceSpeaker(
            client: SentenceTTSClientFactory.make(ttsConfiguration),
            apiKeyProvider: apiKeyProvider,
            player: player)
        speaker.onTurnFinished = { [weak self] in self?.handleFinished() }
        speaker.onError = { [weak self] message in self?.onError?(message) }
        let usageProvider = ttsConfiguration.provider.usageProvider
        let model = speaker.modelDescription
        speaker.onUsage = { [weak self] usage in
            self?.onUsage?(AIUsageEvent(
                provider: usageProvider,
                model: model,
                kind: .textToSpeech,
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                audioSeconds: usage.audioSeconds))
        }
    }

    /// 発話を再生する。再生中なら止めて切り替える。開始できなければ false（アラート済み）。
    @discardableResult
    func play(utteranceID: UUID, text: String, style: SpeechStyle) -> Bool {
        stopPlayback()

        // 再生成が要るときはキー無しで空回りする前に伝える（ファイルがあればキー不要）
        let payload = cache.pcmPayload(utteranceID: utteranceID)
        if payload == nil {
            guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
                onError?("TTS 用の API キーが未設定のため再生できません")
                return false
            }
        }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default)
            try audioSession.setActive(true)
            try speaker.prepare()
        } catch {
            onError?("再生の準備に失敗しました: \(error.localizedDescription)")
            deactivateAudioSession()
            return false
        }

        playingUtteranceID = utteranceID
        if let payload {
            DiagnosticsLog.record(
                "replay: ファイル再生 \(utteranceID.uuidString.prefix(8)) \(payload.count)バイト")
            speaker.beginTurn()
            player.enqueue(pcm16Data: payload)
            player.endStream()
        } else {
            DiagnosticsLog.record(
                "replay: 再生成 \(utteranceID.uuidString.prefix(8)) \(text.count)字")
            speaker.beginTurn()
            var chunker = SentenceChunker()
            var sentences = chunker.consume(text)
            if let rest = chunker.flush() {
                sentences.append(rest)
            }
            for sentence in sentences {
                speaker.enqueue(SpeechItem(
                    utteranceID: utteranceID, text: sentence, style: style))
            }
            speaker.endStream()
        }
        return true
    }

    /// 再タップ / セッション開始時の停止。
    func stop() {
        guard playingUtteranceID != nil else { return }
        stopPlayback()
        deactivateAudioSession()
    }

    private func stopPlayback() {
        guard playingUtteranceID != nil else { return }
        playingUtteranceID = nil
        speaker.stopNow()
    }

    private func handleFinished() {
        guard playingUtteranceID != nil else { return }
        playingUtteranceID = nil
        deactivateAudioSession()
        onFinished?()
    }

    private func deactivateAudioSession() {
        // 会話セッションと違いエンジンごと止め、オーディオを他アプリへ返す
        speaker.shutdown()
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation)
    }
}
