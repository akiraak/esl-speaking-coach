import Foundation

/// クラウド TTS のターン単位ストリーミング再生（旧 SentenceSpeaker の AVSpeech 実装を置換）。
/// SentenceChunker が切り出した文を enqueue した順に 1 文ずつ HTTP ストリーミングで取得し、
/// 案 B/C と共用の RealtimeAudioPlayer（24kHz PCM16）へ流す。TTS プロバイダは
/// SentenceTTSClient の実装（OpenAI / Gemini）を差し替えて比較する。
/// 前の文の取得が終わり次第すぐ次の文の取得を始めるので、再生中に次の文のダウンロードが進む。
/// 通知の形（onTurnAudioStarted / onTurnFinished）は旧 SentenceSpeaker と同じ。
@MainActor
final class CloudSentenceSpeaker {
    /// ターン内で最初のバッファ再生を開始した（レイテンシ計測点）。
    var onTurnAudioStarted: (() -> Void)?
    /// endStream 済み かつ キューの文を全部再生し終えた。
    var onTurnFinished: (() -> Void)?
    /// 文単位の取得失敗（その文はスキップして続行する）。
    var onError: ((String) -> Void)?

    private let client: any SentenceTTSClient
    private let apiKeyProvider: @Sendable () -> String?
    private let player = RealtimeAudioPlayer()

    private var sentenceQueue: [String] = []
    private var fetchTask: Task<Void, Never>?
    private var streamEnded = false
    /// stopNow 後に取得途中の古い音声を積まないための世代カウンタ。
    private var turnID = 0

    init(client: any SentenceTTSClient, apiKeyProvider: @escaping @Sendable () -> String?) {
        self.client = client
        self.apiKeyProvider = apiKeyProvider
        player.onTurnAudioStarted = { [weak self] in self?.onTurnAudioStarted?() }
        player.onTurnFinished = { [weak self] in self?.onTurnFinished?() }
    }

    var voiceDescription: String {
        client.voiceDescription
    }

    func prepare() throws {
        try player.prepare()
    }

    func beginTurn() {
        sentenceQueue.removeAll()
        streamEnded = false
        player.beginTurn()
    }

    func enqueue(_ sentence: String) {
        sentenceQueue.append(sentence)
        startFetchingIfIdle()
    }

    /// Claude の SSE が終わったら呼ぶ。以降キューを読み切った時点で onTurnFinished が飛ぶ。
    /// 文が 1 つも積まれていなくても onTurnFinished は発火する（エラー復帰用）。
    func endStream() {
        streamEnded = true
        if fetchTask == nil, sentenceQueue.isEmpty {
            player.endStream()
        }
    }

    /// barge-in やセッション停止時の即時停止。onTurnFinished は発火させない。
    func stopNow() {
        turnID += 1
        sentenceQueue.removeAll()
        fetchTask?.cancel()
        fetchTask = nil
        streamEnded = false
        player.stopNow()
    }

    func shutdown() {
        turnID += 1
        sentenceQueue.removeAll()
        fetchTask?.cancel()
        fetchTask = nil
        player.shutdown()
    }

    private func startFetchingIfIdle() {
        guard fetchTask == nil else { return }
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            sentenceQueue.removeAll()
            onError?("TTS 用の API キーが未設定のため読み上げできません")
            if streamEnded { player.endStream() }
            return
        }
        let startedTurnID = turnID
        fetchTask = Task { [weak self] in
            while true {
                guard let self, !Task.isCancelled, self.turnID == startedTurnID else { return }
                guard !self.sentenceQueue.isEmpty else { break }
                let sentence = self.sentenceQueue.removeFirst()
                do {
                    for try await chunk in self.client.streamPCM(apiKey: apiKey, text: sentence) {
                        guard !Task.isCancelled, self.turnID == startedTurnID else { return }
                        self.player.enqueue(pcm16Data: chunk)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard self.turnID == startedTurnID else { return }
                    self.onError?("読み上げの取得に失敗（この文はスキップ）: \(error.localizedDescription)")
                }
            }
            guard let self, self.turnID == startedTurnID else { return }
            self.fetchTask = nil
            if !self.sentenceQueue.isEmpty {
                // ループを抜けた後に enqueue された文があれば拾い直す
                self.startFetchingIfIdle()
            } else if self.streamEnded {
                self.player.endStream()
            }
        }
    }
}
