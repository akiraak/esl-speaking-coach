import AVFAudio
import Foundation

/// クラウド TTS から届く 24kHz PCM16 mono チャンクを到着順に再生する。
/// AVAudioPlayerNode に Float32 変換したバッファをスケジュールし、
/// ターン内の最初の再生開始と、ストリーム終了後の読み切りを通知する。
@MainActor
final class StreamingAudioPlayer {
    /// ターン内で最初のバッファ再生を開始した（レイテンシ計測点）。
    var onTurnAudioStarted: (() -> Void)?
    /// endStream 済み かつ スケジュールしたバッファを全部再生し終えた。
    var onTurnFinished: (() -> Void)?
    /// マーカー付きバッファの再生が実際に始まった（発話単位の吹き出し表示タイミング）。
    var onMarkerReached: ((UUID) -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// 入力待ちジングル専用ノード。TTS のターン管理（マーカー・完了通知）と混ざらないよう分離する
    private let cuePlayer = AVAudioPlayerNode()
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
    private lazy var startCueBuffer: AVAudioPCMBuffer? = Self.makeCueBuffer(
        kind: .start, format: format)
    private lazy var endCueBuffer: AVAudioPCMBuffer? = Self.makeCueBuffer(
        kind: .end, format: format)

    private var pendingBuffers = 0
    /// スケジュール済みバッファと並行するマーカー列。先頭 = 再生中（または次に再生される）バッファ
    private var markerQueue: [UUID?] = []
    private var streamEnded = false
    private var startedThisTurn = false
    /// stopNow 後に届く古いバッファの完了通知を無視するための世代カウンタ。
    private var turnID = 0
    private var isGraphBuilt = false

    /// 再入可能。割り込み・経路変更で engine が止まった後の再起動にも使う
    /// （ノードの attach/connect は初回のみ、engine.start は毎回行う）。
    func prepare() throws {
        if !isGraphBuilt {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.attach(cuePlayer)
            engine.connect(cuePlayer, to: engine.mainMixerNode, format: format)
            isGraphBuilt = true
        }
        engine.prepare()
        try engine.start()
    }

    func beginTurn() {
        pendingBuffers = 0
        markerQueue.removeAll()
        streamEnded = false
        startedThisTurn = false
    }

    /// marker には発話（吹き出し）の先頭チャンクで utteranceID を渡す。
    /// そのバッファの再生が実際に始まるタイミングで onMarkerReached が発火する。
    func enqueue(pcm16Data: Data, marker: UUID? = nil) {
        guard let buffer = Self.makeBuffer(pcm16Data: pcm16Data, format: format) else { return }
        // 停止済みエンジンへの scheduleBuffer / play は AVAudioEngine のアサートで abort する
        // （docs/plans/end-session-crash.md H1）。経路変更でエンジンが止まったまま積み続けて
        // 無音になっていたので、まず起こし直し、起こせなければ積まずに捨てる
        // （docs/plans/archive/speaker-no-audio.md）
        guard ensureEngineRunning() else { return }
        let wasIdle = pendingBuffers == 0
        pendingBuffers += 1
        markerQueue.append(marker)
        let scheduledTurnID = turnID
        player.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in self?.handleBufferFinished(turnID: scheduledTurnID) }
        }
        if !player.isPlaying {
            player.play()
        }
        if !startedThisTurn {
            startedThisTurn = true
            onTurnAudioStarted?()
        }
        if wasIdle {
            fireMarkerAtHead()
        }
    }

    /// エンジンが止まっていたら起こす（経路変更で停止することがある）。
    /// 起こせなかった場合だけ false ―― セッション終了直後など、もう鳴らす先が無いケース。
    private func ensureEngineRunning() -> Bool {
        if engine.isRunning { return true }
        do {
            try prepare()
            DiagnosticsLog.record("player: エンジンが止まっていたので再起動した")
            return true
        } catch {
            DiagnosticsLog.record(
                "!! player: エンジンを再起動できず音声を破棄した: \(error.localizedDescription)")
            return false
        }
    }

    /// 入力の窓の開始 / 終了ジングルを鳴らす。TTS 再生キューとは独立で、ターン管理には影響しない。
    func playCue(_ kind: ListeningCue.Kind) {
        let buffer = kind == .start ? startCueBuffer : endCueBuffer
        guard engine.isRunning, let buffer else { return }
        cuePlayer.scheduleBuffer(buffer)
        if !cuePlayer.isPlaying {
            cuePlayer.play()
        }
    }

    /// 応答ストリームが終わったら呼ぶ。以降キューが尽きた時点で onTurnFinished が飛ぶ。
    func endStream() {
        streamEnded = true
        finishIfDrained()
    }

    /// barge-in やセッション停止時の即時停止。onTurnFinished は発火させない。
    func stopNow() {
        turnID += 1
        pendingBuffers = 0
        markerQueue.removeAll()
        streamEnded = false
        startedThisTurn = true
        player.stop()
    }

    func shutdown() {
        DiagnosticsLog.record(
            "player: shutdown 開始 running=\(engine.isRunning) playing=\(player.isPlaying) "
            + "pending=\(pendingBuffers)")
        turnID += 1
        player.stop()
        cuePlayer.stop()
        engine.stop()
        DiagnosticsLog.record("player: shutdown 完了")
    }

    private func handleBufferFinished(turnID: Int) {
        guard turnID == self.turnID, pendingBuffers > 0 else { return }
        pendingBuffers -= 1
        if !markerQueue.isEmpty {
            markerQueue.removeFirst()
        }
        // 次のバッファの再生が始まった
        fireMarkerAtHead()
        finishIfDrained()
    }

    /// 先頭（= 再生が始まったバッファ）のマーカーを 1 度だけ発火する。
    private func fireMarkerAtHead() {
        guard let head = markerQueue.first, let marker = head else { return }
        markerQueue[0] = nil
        onMarkerReached?(marker)
    }

    private func finishIfDrained() {
        guard streamEnded, pendingBuffers == 0 else { return }
        streamEnded = false
        onTurnFinished?()
    }

    private static func makeCueBuffer(
        kind: ListeningCue.Kind, format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let samples = ListeningCue.makeSamples(kind: kind, sampleRate: format.sampleRate)
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: source.count)
        }
        return buffer
    }

    /// PCM16 little-endian mono → Float32 バッファ。
    private static func makeBuffer(pcm16Data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleCount = pcm16Data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(sampleCount)

        var samples = [Int16](repeating: 0, count: sampleCount)
        _ = samples.withUnsafeMutableBytes { pcm16Data.copyBytes(to: $0) }
        let destination = buffer.floatChannelData![0]
        for index in 0..<sampleCount {
            destination[index] = Float(Int16(littleEndian: samples[index])) / 32768.0
        }
        return buffer
    }
}
