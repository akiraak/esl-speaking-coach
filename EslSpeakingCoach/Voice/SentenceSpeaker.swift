import AVFAudio
import Foundation

/// AVSpeechSynthesizer のターン単位ラッパ。文を enqueue した順に読み上げる。
/// - ターン内で最初に音が鳴った瞬間（レイテンシ計測点）と、
///   ストリーム終了後にキューを読み切った瞬間を通知する。
@MainActor
final class SentenceSpeaker: NSObject {
    /// ターン内で最初のうたい出し（AVSpeechSynthesizer の didStart）。
    var onTurnAudioStarted: (() -> Void)?
    /// ストリーム終了済み かつ キューを全部読み終えた。
    var onTurnFinished: (() -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?
    private var enqueuedCount = 0
    private var finishedCount = 0
    private var streamEnded = false
    private var startedThisTurn = false

    override init() {
        voice = Self.bestEnglishVoice()
        super.init()
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = true
    }

    var voiceDescription: String {
        guard let voice else { return "(default)" }
        return "\(voice.name) [\(qualityLabel(voice.quality))]"
    }

    func beginTurn() {
        enqueuedCount = 0
        finishedCount = 0
        streamEnded = false
        startedThisTurn = false
    }

    func enqueue(_ sentence: String) {
        let utterance = AVSpeechUtterance(string: sentence)
        utterance.voice = voice
        enqueuedCount += 1
        synthesizer.speak(utterance)
    }

    /// SSE が終わったら呼ぶ。以降キューが尽きた時点で onTurnFinished が飛ぶ。
    func endStream() {
        streamEnded = true
        finishTurnIfDrained()
    }

    /// barge-in やセッション停止時の即時停止。onTurnFinished は発火させない。
    func stopNow() {
        streamEnded = false
        enqueuedCount = 0
        finishedCount = 0
        startedThisTurn = true
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func handleUtteranceStarted() {
        guard !startedThisTurn else { return }
        startedThisTurn = true
        onTurnAudioStarted?()
    }

    private func handleUtteranceEnded() {
        guard finishedCount < enqueuedCount else { return }
        finishedCount += 1
        finishTurnIfDrained()
    }

    private func finishTurnIfDrained() {
        guard streamEnded, finishedCount == enqueuedCount else { return }
        streamEnded = false
        onTurnFinished?()
    }

    /// en-US の中で最も品質の高い声を選ぶ（premium > enhanced > default）。
    private static func bestEnglishVoice() -> AVSpeechSynthesisVoice? {
        let candidates = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en-US") }
        return candidates.first { $0.quality == .premium }
            ?? candidates.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    private func qualityLabel(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: return "premium"
        case .enhanced: return "enhanced"
        default: return "default"
        }
    }
}

extension SentenceSpeaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.handleUtteranceStarted() }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.handleUtteranceEnded() }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.handleUtteranceEnded() }
    }
}
