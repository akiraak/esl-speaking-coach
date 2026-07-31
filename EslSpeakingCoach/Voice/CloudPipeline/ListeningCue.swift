import Foundation

/// 音声入力の窓の開始 / 終了を知らせるジングルの波形合成。
/// 音源ファイルは持たず、短い 2 音のチャイム（サイン波 + アタック / 減衰包絡）を生成する。
/// 開始は上昇 2 音、終了は聞き分けられる下降 2 音（docs/plans/archive/turn-gated-voice-input.md）。
enum ListeningCue {
    enum Kind: Sendable {
        /// 入力待ち（listening）が始まった = 話してよい
        case start
        /// 発話終端を受け付けて入力の窓が閉じた
        case end
    }

    /// mono の Float32 サンプル列（約 0.3 秒）。振幅は ±1 に収まり、先頭・末尾はほぼ 0（クリック防止）。
    static func makeSamples(kind: Kind = .start, sampleRate: Double) -> [Float] {
        let notes: [(frequency: Double, duration: Double)] =
            switch kind {
            case .start:
                [
                    (659.25, 0.11),  // E5
                    (880.00, 0.16),  // A5
                ]
            case .end:
                [
                    (880.00, 0.11),  // A5
                    (659.25, 0.16),  // E5
                ]
            }
        let amplitude = 0.3
        let gapSamples = Int(0.02 * sampleRate)
        var samples: [Float] = []
        for (index, note) in notes.enumerated() {
            if index > 0 {
                samples.append(contentsOf: [Float](repeating: 0, count: gapSamples))
            }
            let count = Int(note.duration * sampleRate)
            let attackCount = max(1, Int(0.008 * sampleRate))
            for n in 0..<count {
                let attack = min(Double(n) / Double(attackCount), 1)
                let decay = pow(1 - Double(n) / Double(count), 1.5)
                let phase = 2 * Double.pi * note.frequency * Double(n) / sampleRate
                samples.append(Float(amplitude * attack * decay * sin(phase)))
            }
        }
        return samples
    }
}
