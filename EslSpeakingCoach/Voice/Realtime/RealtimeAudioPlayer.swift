import AVFAudio
import Foundation

/// Realtime API から届く 24kHz PCM16 mono チャンクを到着順に再生する。
/// AVAudioPlayerNode に Float32 変換したバッファをスケジュールし、
/// ターン内の最初の再生開始と、ストリーム終了後の読み切りを通知する（SentenceSpeaker と同じ通知形）。
@MainActor
final class RealtimeAudioPlayer {
    /// ターン内で最初のバッファ再生を開始した（レイテンシ計測点）。
    var onTurnAudioStarted: (() -> Void)?
    /// endStream 済み かつ スケジュールしたバッファを全部再生し終えた。
    var onTurnFinished: (() -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!

    private var pendingBuffers = 0
    private var streamEnded = false
    private var startedThisTurn = false
    /// stopNow 後に届く古いバッファの完了通知を無視するための世代カウンタ。
    private var turnID = 0

    func prepare() throws {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
    }

    func beginTurn() {
        pendingBuffers = 0
        streamEnded = false
        startedThisTurn = false
    }

    func enqueue(pcm16Data: Data) {
        guard let buffer = Self.makeBuffer(pcm16Data: pcm16Data, format: format) else { return }
        pendingBuffers += 1
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
        streamEnded = false
        startedThisTurn = true
        player.stop()
    }

    func shutdown() {
        turnID += 1
        player.stop()
        engine.stop()
    }

    private func handleBufferFinished(turnID: Int) {
        guard turnID == self.turnID, pendingBuffers > 0 else { return }
        pendingBuffers -= 1
        finishIfDrained()
    }

    private func finishIfDrained() {
        guard streamEnded, pendingBuffers == 0 else { return }
        streamEnded = false
        onTurnFinished?()
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
