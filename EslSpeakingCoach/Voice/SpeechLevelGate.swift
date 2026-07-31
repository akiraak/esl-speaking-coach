import Foundation

/// サーバ VAD が切り出したセグメント 1 件の音量統計（`SegmentLevelMeter` が作る）。
struct SpeechSegmentLevels: Sendable, Equatable {
    /// セグメント区間の RMS 最大値（口元の声か遠くの音かを最もよく分ける）
    var peak: Float
    /// セグメント区間の RMS 平均
    var mean: Float
    /// 直前の非発話区間から推定した暗騒音（RMS の移動中央値）
    var noiseFloor: Float
    /// 集計に使ったタップバッファ数。0 なら計測できていない（判定に使わない）
    var sampleCount: Int

    /// 暗騒音に対する倍率。フロアが 0 のときは判定不能として nil
    var snr: Float? {
        guard noiseFloor > 0 else { return nil }
        return peak / noiseFloor
    }

    /// 管理画面の会話ログ用の 1 行（閾値を後から見直すために数値を残す）。
    var summaryLine: String {
        let ratio = snr.map { String(format: "%.1f", $0) } ?? "-"
        return String(
            format: "peak %.4f / mean %.4f / floor %.4f / 比 %@ / %d buf",
            peak, mean, noiseFloor, ratio, sampleCount)
    }
}

/// セグメントの音量が「部屋の暗騒音と大差ない」なら、書き起こしの内容に関わらず捨てる判定。
/// 本人の声（口元 20〜40cm）と部屋の向こうのテレビ・家族の声は入力レベルが大きく違うことを使う。
///
/// テレビが鳴りっぱなしの部屋では**暗騒音の推定自体が持ち上がる**ため、
/// 「それより明確に大きい音」＝ 本人の声だけが通る。これがこのゲートの効きどころ。
///
/// 取りこぼし（本人の発話を捨てる）の害の方が大きいので、**判定不能なら必ず採用側へ倒す**。
enum SpeechLevelGate {
    struct Thresholds: Sendable, Equatable {
        /// 暗騒音の何倍のピークがあれば本人の発話とみなすか
        var snrRatio: Float = 3.0
        /// 静かな部屋では暗騒音がほぼ 0 になり比が無意味に大きくなるため、
        /// ピークの絶対値でも下限を設ける（これ未満は何も録れていないに等しい）
        var minimumPeak: Float = 0.01
        /// 暗騒音の推定が何らかの理由で高く出ていても、これだけ大きければ無条件に採用する保険
        var unconditionalPeak: Float = 0.05
        /// 暗騒音・ピークの推定が安定する最小バッファ数（1 バッファ ≒ 43ms）
        var minimumSampleCount = 3
    }

    enum Verdict: Sendable, Equatable {
        case accepted
        /// ピークが暗騒音に対して十分大きくない（遠くの声・物音）
        case rejectedNearNoiseFloor
        /// ピークの絶対値が小さすぎる（実質無音）
        case rejectedTooQuiet

        var isAccepted: Bool { self == .accepted }

        var reason: String? {
            switch self {
            case .accepted: return nil
            case .rejectedNearNoiseFloor: return "暗騒音との差が小さい"
            case .rejectedTooQuiet: return "音量が小さすぎる"
            }
        }
    }

    /// - Parameter levels: 計測できなかった場合は nil（テキスト入力・マイク未起動など）。採用側へ倒す
    static func verdict(
        for levels: SpeechSegmentLevels?, thresholds: Thresholds = Thresholds()
    ) -> Verdict {
        guard let levels, levels.sampleCount >= thresholds.minimumSampleCount else { return .accepted }
        if levels.peak >= thresholds.unconditionalPeak { return .accepted }
        if levels.peak < thresholds.minimumPeak { return .rejectedTooQuiet }
        // フロアが取れていない（起動直後など）なら比を使えないので採用側へ倒す
        guard let snr = levels.snr else { return .accepted }
        return snr >= thresholds.snrRatio ? .accepted : .rejectedNearNoiseFloor
    }
}

/// マイクのタップバッファごとの RMS を受け取り、暗騒音（非発話区間の移動中央値）と
/// セグメント区間の統計を作る。`AudioTapRouter` がロックの下で駆動するため純粋な値型にする。
struct SegmentLevelMeter: Sendable {
    /// 暗騒音の推定に使う直近サンプル数（1 サンプル ≒ 43ms なので約 5 秒）
    var noiseWindow = 128
    /// `speech_started` はサーバ VAD の判定 + ネットワーク往復のぶん遅れて届くため、
    /// セグメント開始時に直近このサンプル数（約 0.5 秒）まで遡ってピークに含める
    var lookbackWindow = 12

    private var recent: [Float] = []
    private var noiseSamples: [Float] = []
    private var segment: Segment?

    private struct Segment {
        var peak: Float
        var sum: Float
        var count: Int
    }

    /// 暗騒音の更新を止めるか。読み上げ中は、エコーキャンセルが効かない端末で
    /// スピーカー出力が回り込み、フロアが不当に持ち上がって本人の発話を弾いてしまう
    var isNoiseFloorUpdateSuppressed = false

    /// 現時点の暗騒音の推定値（未推定なら 0）。`ClientSpeechEndpointer` が毎バッファ参照する
    /// （エンドポインタ側で二重推定しないための読み出し口）。
    var currentNoiseFloor: Float { Self.median(noiseSamples) }

    /// タップバッファ 1 つぶんの RMS を取り込む（オーディオスレッドから毎回呼ばれる）。
    mutating func record(_ level: Float) {
        recent.append(level)
        if recent.count > lookbackWindow { recent.removeFirst(recent.count - lookbackWindow) }

        if var active = segment {
            active.peak = max(active.peak, level)
            active.sum += level
            active.count += 1
            segment = active
        } else if !isNoiseFloorUpdateSuppressed {
            noiseSamples.append(level)
            if noiseSamples.count > noiseWindow {
                noiseSamples.removeFirst(noiseSamples.count - noiseWindow)
            }
        }
    }

    /// `speech_started` で呼ぶ。直近の遡り分をピークの初期値にする。
    mutating func beginSegment() {
        segment = Segment(peak: recent.max() ?? 0, sum: 0, count: 0)
    }

    /// `speech_stopped` で呼ぶ。区間が計測できていなければ nil（判定は採用側へ倒す）。
    mutating func endSegment() -> SpeechSegmentLevels? {
        guard let segment else { return nil }
        self.segment = nil
        guard segment.count > 0 else { return nil }
        return SpeechSegmentLevels(
            peak: segment.peak,
            mean: segment.sum / Float(segment.count),
            noiseFloor: Self.median(noiseSamples),
            sampleCount: segment.count)
    }

    /// 突発音（咳・ドアの音）に引きずられないよう平均ではなく中央値を使う。
    static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
}
