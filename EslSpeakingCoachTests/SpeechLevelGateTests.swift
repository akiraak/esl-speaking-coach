import XCTest

@testable import EslSpeakingCoach

/// 雑音セグメントを音量で落とすレベルゲート（docs/plans/noise-input-rejection.md Phase 3）。
/// 本人の発話を取りこぼす方が体験上の害が大きいので、**判定不能なら採用**が全体の原則。
final class SpeechLevelGateTests: XCTestCase {
    // MARK: - 採否の判定

    /// 口元の声: 暗騒音よりはっきり大きい
    func testAcceptsSpeechWellAboveNoiseFloor() {
        let levels = SpeechSegmentLevels(peak: 0.12, mean: 0.05, noiseFloor: 0.004, sampleCount: 20)
        XCTAssertEqual(SpeechLevelGate.verdict(for: levels), .accepted)
    }

    /// 部屋の向こうのテレビ: 鳴りっぱなしなので暗騒音自体が持ち上がり、比が出ない
    func testRejectsDistantVoiceNearNoiseFloor() {
        let levels = SpeechSegmentLevels(peak: 0.020, mean: 0.014, noiseFloor: 0.012, sampleCount: 20)
        XCTAssertEqual(SpeechLevelGate.verdict(for: levels), .rejectedNearNoiseFloor)
    }

    /// 静かな部屋の小さな物音: 比では通っても絶対値が小さすぎる
    func testRejectsTooQuietSegmentEvenWithHighRatio() {
        let levels = SpeechSegmentLevels(peak: 0.004, mean: 0.002, noiseFloor: 0.0002, sampleCount: 20)
        XCTAssertEqual(SpeechLevelGate.verdict(for: levels), .rejectedTooQuiet)
    }

    /// 暗騒音の推定が何らかの理由で高く出ていても、十分大きい入力は無条件で通す（取りこぼし防止の保険）
    func testAcceptsLoudSegmentEvenWhenNoiseFloorLooksHigh() {
        let levels = SpeechSegmentLevels(peak: 0.09, mean: 0.06, noiseFloor: 0.08, sampleCount: 20)
        XCTAssertEqual(SpeechLevelGate.verdict(for: levels), .accepted)
    }

    /// 静かな部屋（フロアがほぼ 0）で普通に話した場合は必ず通ること
    func testAcceptsNormalSpeechInSilentRoom() {
        let levels = SpeechSegmentLevels(peak: 0.045, mean: 0.02, noiseFloor: 0.0005, sampleCount: 20)
        XCTAssertEqual(SpeechLevelGate.verdict(for: levels), .accepted)
    }

    // MARK: - 判定不能なら採用側へ倒す

    func testAcceptsWhenLevelsAreMissing() {
        XCTAssertEqual(SpeechLevelGate.verdict(for: nil), .accepted)
    }

    func testAcceptsWhenSampleCountIsTooSmall() {
        let levels = SpeechSegmentLevels(peak: 0.001, mean: 0.001, noiseFloor: 0.02, sampleCount: 1)
        XCTAssertEqual(SpeechLevelGate.verdict(for: levels), .accepted)
    }

    func testAcceptsWhenNoiseFloorIsUnknown() {
        // 起動直後などフロアのサンプルが無い（0）と比を計算できない
        let levels = SpeechSegmentLevels(peak: 0.02, mean: 0.015, noiseFloor: 0, sampleCount: 20)
        XCTAssertEqual(SpeechLevelGate.verdict(for: levels), .accepted)
    }

    // MARK: - 閾値の調整

    func testThresholdsAreConfigurable() {
        let levels = SpeechSegmentLevels(peak: 0.030, mean: 0.02, noiseFloor: 0.010, sampleCount: 20)
        var thresholds = SpeechLevelGate.Thresholds()
        XCTAssertEqual(SpeechLevelGate.verdict(for: levels, thresholds: thresholds), .accepted)
        thresholds.snrRatio = 4
        XCTAssertEqual(
            SpeechLevelGate.verdict(for: levels, thresholds: thresholds), .rejectedNearNoiseFloor)
    }

    // MARK: - 計測（SegmentLevelMeter）

    func testMeterEstimatesNoiseFloorFromNonSpeechSamplesOnly() {
        var meter = SegmentLevelMeter()
        for _ in 0..<40 { meter.record(0.005) }  // 暗騒音
        meter.beginSegment()
        for _ in 0..<20 { meter.record(0.12) }  // 発話
        let levels = try? XCTUnwrap(meter.endSegment())

        XCTAssertEqual(levels?.peak ?? 0, 0.12, accuracy: 0.0001)
        XCTAssertEqual(levels?.mean ?? 0, 0.12, accuracy: 0.0001)
        // 発話中のサンプルはフロアに混ぜない
        XCTAssertEqual(levels?.noiseFloor ?? 0, 0.005, accuracy: 0.0001)
        XCTAssertEqual(levels?.sampleCount, 20)
    }

    /// 突発的な物音 1 発でフロアが跳ね上がらないこと（平均ではなく中央値を使う理由）
    func testMeterNoiseFloorIsRobustAgainstSpikes() {
        var meter = SegmentLevelMeter()
        for _ in 0..<40 { meter.record(0.004) }
        meter.record(0.9)  // ドアの音
        meter.beginSegment()
        for _ in 0..<10 { meter.record(0.08) }
        let levels = meter.endSegment()
        XCTAssertEqual(levels?.noiseFloor ?? 0, 0.004, accuracy: 0.0001)
    }

    /// speech_started はサーバ VAD + ネットワークのぶん遅れて届くため、
    /// 語頭がセグメント開始前に鳴っていてもピークに含める
    func testMeterIncludesLookbackInPeak() {
        var meter = SegmentLevelMeter()
        for _ in 0..<20 { meter.record(0.003) }
        meter.record(0.20)  // 語頭。speech_started はこの直後に届く
        meter.beginSegment()
        for _ in 0..<10 { meter.record(0.02) }
        let levels = meter.endSegment()
        XCTAssertEqual(levels?.peak ?? 0, 0.20, accuracy: 0.0001)
    }

    /// 読み上げ中は暗騒音を更新しない（VP 無効端末でスピーカー音が回り込み、
    /// フロアが持ち上がって本人の発話を弾くのを防ぐ）
    func testMeterSkipsNoiseFloorUpdatesWhileSuppressed() {
        var meter = SegmentLevelMeter()
        for _ in 0..<40 { meter.record(0.004) }
        meter.isNoiseFloorUpdateSuppressed = true
        for _ in 0..<40 { meter.record(0.30) }  // 読み上げの回り込み
        meter.isNoiseFloorUpdateSuppressed = false
        meter.beginSegment()
        for _ in 0..<10 { meter.record(0.05) }
        let levels = meter.endSegment()

        XCTAssertEqual(levels?.noiseFloor ?? 0, 0.004, accuracy: 0.0001)
        XCTAssertEqual(SpeechLevelGate.verdict(for: levels), .accepted)
    }

    func testMeterReturnsNilWhenSegmentHasNoSamples() {
        var meter = SegmentLevelMeter()
        for _ in 0..<10 { meter.record(0.004) }
        meter.beginSegment()
        XCTAssertNil(meter.endSegment())
        // begin していなければ当然 nil
        XCTAssertNil(meter.endSegment())
    }

    /// マイクが止まっている間（テキスト入力モード等）は統計が作れず、判定は採用側へ倒れる
    func testMeterWithoutAnySamplesFallsBackToAccept() {
        var meter = SegmentLevelMeter()
        meter.beginSegment()
        XCTAssertEqual(SpeechLevelGate.verdict(for: meter.endSegment()), .accepted)
    }

    func testMedianHandlesEvenAndOddCounts() {
        XCTAssertEqual(SegmentLevelMeter.median([]), 0)
        XCTAssertEqual(SegmentLevelMeter.median([0.3, 0.1, 0.2]), 0.2, accuracy: 0.0001)
        XCTAssertEqual(SegmentLevelMeter.median([0.4, 0.1, 0.2, 0.3]), 0.25, accuracy: 0.0001)
    }

    /// 暗騒音の推定は直近の窓だけを見る（環境が変わったら追従する）
    func testMeterNoiseFloorFollowsRecentEnvironment() {
        var meter = SegmentLevelMeter()
        meter.noiseWindow = 10
        for _ in 0..<10 { meter.record(0.001) }  // 静かだった頃
        for _ in 0..<10 { meter.record(0.020) }  // テレビが点いた
        meter.beginSegment()
        for _ in 0..<10 { meter.record(0.030) }
        let levels = meter.endSegment()

        XCTAssertEqual(levels?.noiseFloor ?? 0, 0.020, accuracy: 0.0001)
        // 持ち上がったフロアに対して 1.5 倍しかないテレビの声は落ちる
        XCTAssertEqual(SpeechLevelGate.verdict(for: levels), .rejectedNearNoiseFloor)
    }
}
