import Foundation

/// 読み上げキューに積む 1 文。utteranceID は発話（= 吹き出し）単位で共有する。
struct SpeechItem: Sendable {
    let utteranceID: UUID
    let text: String
    let style: SpeechStyle
}

/// クラウド TTS のターン単位ストリーミング再生。
/// ScriptStreamChunker が切り出した文を enqueue した順に 1 文ずつ HTTP ストリーミングで取得し、
/// StreamingAudioPlayer（24kHz PCM16）へ流す。発話ごとに SpeechStyle（voice / スタイル前置文）を
/// 切り替え、発話の音声が実際に再生開始されたタイミングを onUtteranceAudioStarted で通知する
/// （吹き出しを読み上げ開始時に表示するため）。
/// 前の文の取得が終わり次第すぐ次の文の取得を始めるので、再生中に次の文のダウンロードが進む。
@MainActor
final class CloudSentenceSpeaker {
    /// ターン内で最初のバッファ再生を開始した（レイテンシ計測点）。
    var onTurnAudioStarted: (() -> Void)?
    /// endStream 済み かつ キューの文を全部再生し終えた。
    var onTurnFinished: (() -> Void)?
    /// 発話の音声再生が実際に始まった。
    var onUtteranceAudioStarted: ((UUID) -> Void)?
    /// 文単位の取得失敗（その文はスキップして続行する）。
    var onError: ((String) -> Void)?
    /// TTS 1 リクエスト（1 文）分の利用量（料金記録用）。
    var onUsage: ((TTSUsage) -> Void)?

    private let client: any SentenceTTSClient
    private let apiKeyProvider: @Sendable () -> String?
    private let player = StreamingAudioPlayer()

    private var sentenceQueue: [SpeechItem] = []
    private var fetchTask: Task<Void, Never>?
    private var streamEnded = false
    /// 直前にマーカーを積んだ発話。同一発話の 2 文目以降にはマーカーを付けない
    private var lastMarkedUtteranceID: UUID?
    /// stopNow 後に取得途中の古い音声を積まないための世代カウンタ。
    private var turnID = 0

    init(client: any SentenceTTSClient, apiKeyProvider: @escaping @Sendable () -> String?) {
        self.client = client
        self.apiKeyProvider = apiKeyProvider
        player.onTurnAudioStarted = { [weak self] in self?.onTurnAudioStarted?() }
        player.onTurnFinished = { [weak self] in self?.onTurnFinished?() }
        player.onMarkerReached = { [weak self] id in self?.onUtteranceAudioStarted?(id) }
    }

    var modelDescription: String {
        client.modelDescription
    }

    func prepare() throws {
        try player.prepare()
    }

    func beginTurn() {
        sentenceQueue.removeAll()
        streamEnded = false
        lastMarkedUtteranceID = nil
        player.beginTurn()
    }

    /// 入力待ち（listening）開始のジングルを鳴らす。読み上げキューとは独立。
    func playListeningCue() {
        player.playCue(.start)
    }

    /// 発話終端を受け付けて入力の窓が閉じたことを知らせるジングル（下降 2 音）。
    func playInputEndCue() {
        player.playCue(.end)
    }

    func enqueue(_ item: SpeechItem) {
        sentenceQueue.append(item)
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
        DiagnosticsLog.record(
            "speaker: shutdown 開始 未読み上げ=\(sentenceQueue.count) 取得中=\(fetchTask != nil)")
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
                let item = self.sentenceQueue.removeFirst()
                // 発話の先頭チャンクにだけマーカーを付ける（1 文目の TTS が丸ごと失敗したら 2 文目が引き継ぐ）
                var pendingMarker: UUID? =
                    item.utteranceID == self.lastMarkedUtteranceID ? nil : item.utteranceID
                do {
                    for try await chunk in self.client.streamAudio(
                        apiKey: apiKey, text: item.text, style: item.style) {
                        guard !Task.isCancelled, self.turnID == startedTurnID else { return }
                        switch chunk {
                        case .pcm(let pcm):
                            self.player.enqueue(pcm16Data: pcm, marker: pendingMarker)
                            if pendingMarker != nil {
                                self.lastMarkedUtteranceID = item.utteranceID
                                pendingMarker = nil
                            }
                        case .usage(let usage):
                            self.onUsage?(usage)
                        }
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
