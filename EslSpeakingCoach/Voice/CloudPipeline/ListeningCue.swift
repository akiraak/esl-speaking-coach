import Foundation

/// 入力待ち（listening）開始を知らせるジングルの波形合成。
/// 音源ファイルは持たず、短い 2 音の上昇チャイム（サイン波 + アタック / 減衰包絡）を生成する。
enum ListeningCue {
    /// mono の Float32 サンプル列（約 0.3 秒）。振幅は ±1 に収まり、先頭・末尾はほぼ 0（クリック防止）。
    static func makeSamples(sampleRate: Double) -> [Float] {
        let notes: [(frequency: Double, duration: Double)] = [
            (659.25, 0.11),  // E5
            (880.00, 0.16),  // A5
        ]
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
