import Foundation

/// クライアント側の発話開始・終端検知（エネルギー VAD の状態機械）。
/// gpt-live-transcribe はサーバ VAD 非対応（手動 commit のみ）のため、
/// サーバ VAD が担っていた発話開始（barge-in の起点）と発話終端（commit の起点）を
/// タップバッファごとの RMS から判定する（docs/plans/archive/gpt-live-transcribe-adoption.md Phase 1）。
///
/// 暗騒音は自分では推定しない。`SegmentLevelMeter` が推定した値を毎バッファ受け取る
/// （二重推定を避ける。読み上げ中のフロア更新停止も meter 側の仕組みがそのまま効く）。
/// `AudioTapRouter` がロックの下でオーディオスレッドから駆動するため純粋な値型にする。
struct ClientSpeechEndpointer: Sendable {
    struct Thresholds: Sendable, Equatable {
        /// 発話開始とみなす暗騒音への倍率（`SpeechLevelGate.Thresholds` の実機調整値を流用）
        var snrRatio: Float = 3.0
        /// 静かな部屋では暗騒音がほぼ 0 になり比が使えないため、閾値の絶対下限を設ける
        var minimumPeak: Float = 0.01
        /// 暗騒音の推定が何らかの理由で高く出ていても、これだけ大きければ発話とみなす
        /// （閾値の上限。取りこぼし防止の保険）
        var unconditionalPeak: Float = 0.05
        /// 発話開始とみなす閾値超えの継続時間（単発の咳・物音で発火しない）。
        /// 43ms のタップバッファ 3 個ぶん。判定が遅れるぶんは送信側の遡り（lookback）が吸収する
        var minimumSpeechDuration: TimeInterval = 0.12
        /// 発話終端とみなす無音の継続時間。サーバ VAD で使っていた
        /// `silence_duration_ms` 800（ESL 学習者の考えるポーズ対策）と同値
        var silenceDuration: TimeInterval = 0.8
        /// 発話開始判定時に prefix padding としてセグメントへ含める直近音声の長さ。
        /// セグメント間で認識文脈が引き継がれないため語頭の欠けは精度に直撃する。
        /// 状態機械自身は使わず、送信ゲート側がリングバッファ長として読む
        var lookbackDuration: TimeInterval = 0.5
        /// フェイルセーフ: 発話開始からこの時間で強制終端する。エネルギー VAD は
        /// 持続的な環境音（テレビ等）で終端が出ないことがあり、放置すると append と
        /// 課金が無制限に伸びる（サーバ VAD 時代には無かった故障モード）
        var maxSegmentDuration: TimeInterval = 60
    }

    enum Event: Sendable, Equatable {
        case speechStarted
        /// forced = true は `maxSegmentDuration` 到達の強制終端（無音による通常終端ではない）
        case speechStopped(forced: Bool)
    }

    var thresholds: Thresholds

    private enum Phase: Sendable { case idle, speaking }
    private var phase = Phase.idle
    /// idle 中の閾値超えの継続時間（途切れたら 0 に戻す）
    private var speechRun: TimeInterval = 0
    /// speaking 中の閾値未満の継続時間（音声が戻ったら 0 に戻す）
    private var silenceRun: TimeInterval = 0
    /// 発話開始（閾値超えの初回バッファ）からの経過時間
    private var segmentDuration: TimeInterval = 0

    init(thresholds: Thresholds = Thresholds()) {
        self.thresholds = thresholds
    }

    /// 発話中（speechStarted 発行済みで終端前）か。送信ゲートの開閉判定に使う。
    var isSpeaking: Bool { phase == .speaking }

    /// タップバッファ 1 つぶんの RMS を取り込み、状態が変わればイベントを返す。
    /// - Parameters:
    ///   - level: バッファの RMS
    ///   - duration: バッファの実時間（フレーム数 ÷ サンプルレート）。バッファ数ではなく
    ///     時間で数えることで、Bluetooth HFP 等でサンプルレートが変わっても判定基準を保つ
    ///   - noiseFloor: `SegmentLevelMeter` が推定した暗騒音（未推定なら 0 =
    ///     `minimumPeak` の絶対値判定へフォールバックする）
    mutating func record(level: Float, duration: TimeInterval, noiseFloor: Float) -> Event? {
        let threshold = min(
            max(noiseFloor * thresholds.snrRatio, thresholds.minimumPeak),
            thresholds.unconditionalPeak)

        switch phase {
        case .idle:
            guard level >= threshold else {
                speechRun = 0
                return nil
            }
            speechRun += duration
            guard speechRun >= thresholds.minimumSpeechDuration else { return nil }
            phase = .speaking
            segmentDuration = speechRun
            speechRun = 0
            silenceRun = 0
            return .speechStarted

        case .speaking:
            segmentDuration += duration
            if level < threshold {
                silenceRun += duration
                if silenceRun >= thresholds.silenceDuration {
                    phase = .idle
                    return .speechStopped(forced: false)
                }
            } else {
                silenceRun = 0
            }
            if segmentDuration >= thresholds.maxSegmentDuration {
                phase = .idle
                return .speechStopped(forced: true)
            }
            return nil
        }
    }

    /// STT 再接続などでセグメントを仕切り直すとき呼ぶ。進行中の発話は破棄して idle に戻る
    /// （終端イベントは発行しない。送信ゲート側も合わせて破棄すること）。
    mutating func reset() {
        phase = .idle
        speechRun = 0
        silenceRun = 0
        segmentDuration = 0
    }
}
