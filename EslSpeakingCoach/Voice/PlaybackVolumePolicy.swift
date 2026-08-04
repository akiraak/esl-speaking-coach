import Foundation

/// 読み上げ音量の下限を潰すためのソフトウェアゲイン
/// （docs/plans/tts-volume-not-following.md Phase 1）。
///
/// ## なぜ要るか
///
/// 会話セッションは `.playAndRecord` + `mode: .voiceChat` を使う。この組み合わせだと音量が
/// **通話音量チャンネル**として扱われ、電話と同じく「ボリュームボタンで消音できない」。
/// 実機で測ると `AVAudioSession.outputVolume` は 0.05 で打ち止めになり、そこでも読み上げは
/// はっきり聞こえる（0.30 → 0.25 → 0.20 → 0.15 → 0.05 で停止）。
///
/// `mode` を `.default` にすればメディア音量に戻って 0.00 まで下がるが、`.voiceChat` の AGC が
/// 外れて**マイクの入力レベルが激減し、調整済みの VAD しきい値が丸ごと合わなくなる**
/// （実機で確認済み。入力ゲージがほとんど振れない）。入力を犠牲にはできないので、
/// モードは `.voiceChat` のまま**出力側でゲインを掛けて**下限を 0 まで届かせる。
///
/// ## カーブ
///
/// ```
/// gain 1.0 |                                  ┌──────
///          |                              ╱───┘
///          |                        ╱────┘
///          |              ╱────────┘
/// gain 0.0 |─────────────┘
///          └───────────────────────────────────────
///           0  floor(0.05)          taperEnd(0.50)  1.0   ← outputVolume
/// ```
///
/// - `floor` 以下は無音。ボタンを下げ切れば消える（これが元の要望）
/// - `floor`〜`taperEnd` は **dB 直線**で持ち上げる。振幅の線形補間だと下限の 1 段上が
///   いきなり −9.5dB（振幅 1/3）になって「まだ大きすぎる」ため（実機フィードバック）、
///   `minimumDecibels` から 0dB へ等間隔に並べて刻みを効かせる
/// - `taperEnd` 以上は素通し。普段使う音量域の聞こえ方はほぼ変えない
///
/// 実機で刻める 0.05 刻みでのゲイン（参考値）:
///
/// | outputVolume | 0.05 | 0.10 | 0.15 | 0.20 | 0.30 | 0.40 | 0.50〜 |
/// | --- | --- | --- | --- | --- | --- | --- | --- |
/// | dB | 無音 | -35.6 | -31.1 | -26.7 | -17.8 | -8.9 | 0 |
/// | ゲイン | 0.00 | 0.017 | 0.028 | 0.046 | 0.13 | 0.36 | 1.00 |
///
/// ハードウェアの音量自体は OS が別に掛けるので、実際の音量は
/// `outputVolume × gain(outputVolume)` になる。
enum PlaybackVolumePolicy {
    /// 通話音量チャンネルの下限（実機実測）。これ以下には OS が下げてくれない
    static let floor: Float = 0.05
    /// ここから上は素通し。floor との間を dB 直線で絞る
    static let taperEnd: Float = 0.5
    /// `floor` の直上に割り当てるゲイン（dB）。ここから 0dB まで等間隔に並べる
    static let minimumDecibels: Float = -40

    /// システム音量に対して読み上げへ掛けるゲイン（0.0〜1.0）。
    static func gain(systemVolume: Float) -> Float {
        guard systemVolume > floor else { return 0 }
        guard systemVolume < taperEnd else { return 1 }
        let progress = (systemVolume - floor) / (taperEnd - floor)
        let decibels = minimumDecibels * (1 - progress)
        return Float(pow(10.0, Double(decibels) / 20.0))
    }
}
