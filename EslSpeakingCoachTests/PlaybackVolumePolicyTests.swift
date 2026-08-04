import Foundation
import Testing

@testable import EslSpeakingCoach

/// 読み上げ音量の下限潰し（docs/plans/tts-volume-not-following.md）。
/// `.voiceChat` の通話音量チャンネルは 0.05 で打ち止めになり消音できないため、
/// その下限ぶんを出力側のゲインで潰す。
struct PlaybackVolumePolicyTests {
    @Test("下限（実機で打ち止めになる値）まで下げたら無音になる")
    func flooredVolumeIsSilent() {
        #expect(PlaybackVolumePolicy.gain(systemVolume: PlaybackVolumePolicy.floor) == 0)
    }

    /// これが元の不具合。0.05 で鳴り続けていた
    @Test("下限より下（0 を含む）も無音")
    func belowFloorIsSilent() {
        #expect(PlaybackVolumePolicy.gain(systemVolume: 0) == 0)
        #expect(PlaybackVolumePolicy.gain(systemVolume: 0.01) == 0)
    }

    @Test("taperEnd 以上は素通し（今までの聞こえ方を変えない）")
    func aboveTaperEndIsUnchanged() {
        #expect(PlaybackVolumePolicy.gain(systemVolume: PlaybackVolumePolicy.taperEnd) == 1)
        #expect(PlaybackVolumePolicy.gain(systemVolume: 0.5) == 1)
        #expect(PlaybackVolumePolicy.gain(systemVolume: 1) == 1)
    }

    /// 下限と taperEnd の間は dB 直線。中点がちょうど半分の dB になること
    @Test("下限と taperEnd の間は dB 直線で持ち上げる")
    func taperIsLinearInDecibels() {
        let middle = (PlaybackVolumePolicy.floor + PlaybackVolumePolicy.taperEnd) / 2
        let expected = Float(pow(10.0, Double(PlaybackVolumePolicy.minimumDecibels / 2) / 20.0))
        #expect(abs(PlaybackVolumePolicy.gain(systemVolume: middle) - expected) < 0.0001)
    }

    /// 実機で刻める値（0.05 刻み）で単調に増えること
    @Test("刻みごとに単調増加する")
    func gainIncreasesMonotonically() {
        let steps: [Float] = [0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.35, 0.40, 0.45, 0.50]
        let gains = steps.map { PlaybackVolumePolicy.gain(systemVolume: $0) }
        for (lower, upper) in zip(gains, gains.dropFirst()) {
            #expect(lower < upper)
        }
    }

    /// これが 2 回目の実機フィードバック。振幅の線形補間だと下限の 1 段上が
    /// 振幅 1/3（-9.5dB）になって「まだ大きすぎる」だった
    @Test("下限の 1 段上は十分に小さい")
    func firstStepAboveFloorIsQuiet() {
        let gain = PlaybackVolumePolicy.gain(systemVolume: 0.10)
        #expect(gain > 0, "無音ではない（1 段上げたら聞こえる）")
        #expect(gain < 0.05, "振幅 5% 未満まで絞る")
    }

    @Test("ゲインは 0〜1 に収まる")
    func gainStaysInRange() {
        for step in 0...20 {
            let gain = PlaybackVolumePolicy.gain(systemVolume: Float(step) / 20)
            #expect(gain >= 0 && gain <= 1)
        }
    }

    /// 範囲外の入力（KVO が想定外の値を運んでも壊れないこと）
    @Test("範囲外の入力でも破綻しない")
    func outOfRangeInputIsClamped() {
        #expect(PlaybackVolumePolicy.gain(systemVolume: -1) == 0)
        #expect(PlaybackVolumePolicy.gain(systemVolume: 2) == 1)
    }
}
