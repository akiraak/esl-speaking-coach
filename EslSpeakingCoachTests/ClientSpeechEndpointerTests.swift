import XCTest

@testable import EslSpeakingCoach

/// gpt-live-transcribe 用のクライアント側発話終端検知（エネルギー VAD の状態機械。
/// docs/plans/archive/gpt-live-transcribe-adoption.md Phase 1）。
/// 43ms のタップバッファを模した合成レベル系列を入れ、イベント列を検証する。
final class ClientSpeechEndpointerTests: XCTestCase {
    /// 実機の標準的なタップバッファ長（2048 frames @ 48kHz ≒ 43ms）
    private let bufferDuration: TimeInterval = 0.043

    /// 同じレベルのバッファを連続で入れ、発行されたイベントを集める
    private func feed(
        _ endpointer: inout ClientSpeechEndpointer,
        level: Float, buffers: Int, noiseFloor: Float
    ) -> [ClientSpeechEndpointer.Event] {
        var events: [ClientSpeechEndpointer.Event] = []
        for _ in 0..<buffers {
            if let event = endpointer.record(
                level: level, duration: bufferDuration, noiseFloor: noiseFloor)
            {
                events.append(event)
            }
        }
        return events
    }

    // MARK: - 発話開始

    /// 閾値超えが連続して初めて発話開始になる（3 バッファ ≒ 129ms で minimumSpeechDuration 0.12 を満たす）
    func testStartsAfterSustainedSpeech() {
        var endpointer = ClientSpeechEndpointer()
        XCTAssertEqual(feed(&endpointer, level: 0.1, buffers: 2, noiseFloor: 0.004), [])
        XCTAssertFalse(endpointer.isSpeaking)
        XCTAssertEqual(feed(&endpointer, level: 0.1, buffers: 1, noiseFloor: 0.004), [.speechStarted])
        XCTAssertTrue(endpointer.isSpeaking)
    }

    /// 咳・ドアの音など単発の物音では発火しない（連続条件。途切れたらカウントは 0 に戻る）
    func testSingleLoudBufferDoesNotStart() {
        var endpointer = ClientSpeechEndpointer()
        XCTAssertEqual(feed(&endpointer, level: 0.3, buffers: 1, noiseFloor: 0.004), [])
        XCTAssertEqual(feed(&endpointer, level: 0.004, buffers: 5, noiseFloor: 0.004), [])
        XCTAssertEqual(feed(&endpointer, level: 0.3, buffers: 2, noiseFloor: 0.004), [])
        XCTAssertFalse(endpointer.isSpeaking)
    }

    /// 静かな部屋で暗騒音がほぼ 0（比が計算できない）でも、絶対値の下限 minimumPeak で判定できる
    func testStartsWithAbsoluteFallbackWhenFloorIsZero() {
        var endpointer = ClientSpeechEndpointer()
        XCTAssertEqual(feed(&endpointer, level: 0.02, buffers: 3, noiseFloor: 0), [.speechStarted])
    }

    /// minimumPeak 未満の微小レベルはフロア 0 でも発話にしない（実質無音）
    func testIgnoresSubMinimumLevelsWhenFloorIsZero() {
        var endpointer = ClientSpeechEndpointer()
        XCTAssertEqual(feed(&endpointer, level: 0.008, buffers: 20, noiseFloor: 0), [])
    }

    /// 持ち上がった暗騒音と大差ないレベル（部屋の向こうのテレビ）では発火しない
    func testIgnoresLevelsNearRaisedNoiseFloor() {
        var endpointer = ClientSpeechEndpointer()
        XCTAssertEqual(feed(&endpointer, level: 0.03, buffers: 20, noiseFloor: 0.015), [])
    }

    /// 暗騒音の推定が不当に高くても unconditionalPeak 以上の声は必ず拾う（取りこぼし防止の保険）
    func testStartsAboveUnconditionalPeakDespiteHighFloor() {
        var endpointer = ClientSpeechEndpointer()
        XCTAssertEqual(feed(&endpointer, level: 0.06, buffers: 3, noiseFloor: 0.1), [.speechStarted])
    }

    // MARK: - 発話終端

    /// 閾値未満が 800ms 続いたら終端（サーバ VAD の silence_duration_ms と同値）
    func testStopsAfter800msOfSilence() {
        var endpointer = ClientSpeechEndpointer()
        XCTAssertEqual(feed(&endpointer, level: 0.1, buffers: 5, noiseFloor: 0.004), [.speechStarted])
        // 18 バッファ ≒ 774ms ではまだ終端しない
        XCTAssertEqual(feed(&endpointer, level: 0.004, buffers: 18, noiseFloor: 0.004), [])
        XCTAssertTrue(endpointer.isSpeaking)
        // 19 バッファ目（≒ 817ms）で終端
        XCTAssertEqual(
            feed(&endpointer, level: 0.004, buffers: 1, noiseFloor: 0.004),
            [.speechStopped(forced: false)])
        XCTAssertFalse(endpointer.isSpeaking)
    }

    /// 考えながらの短いポーズ（800ms 未満）では切らない。音声が戻れば無音カウントはリセット
    func testShortPauseDoesNotStop() {
        var endpointer = ClientSpeechEndpointer()
        XCTAssertEqual(feed(&endpointer, level: 0.1, buffers: 3, noiseFloor: 0.004), [.speechStarted])
        XCTAssertEqual(feed(&endpointer, level: 0.004, buffers: 15, noiseFloor: 0.004), [])  // ≒ 645ms
        XCTAssertEqual(feed(&endpointer, level: 0.1, buffers: 3, noiseFloor: 0.004), [])  // 話が続く
        // 無音はゼロから数え直し、あらためて 800ms で終端する
        XCTAssertEqual(feed(&endpointer, level: 0.004, buffers: 18, noiseFloor: 0.004), [])
        XCTAssertEqual(
            feed(&endpointer, level: 0.004, buffers: 1, noiseFloor: 0.004),
            [.speechStopped(forced: false)])
    }

    /// 持続的な環境音（テレビ等）で終端が出ないとき、maxSegmentDuration で強制終端する
    /// （append・課金が無制限に伸びるのを防ぐフェイルセーフ）
    func testForceStopsAtMaxSegmentDuration() {
        var thresholds = ClientSpeechEndpointer.Thresholds()
        thresholds.maxSegmentDuration = 1.0  // テスト用に短縮
        var endpointer = ClientSpeechEndpointer(thresholds: thresholds)
        // 3 バッファで開始（segment 129ms）、その後 21 バッファで 1.0 秒を超える
        XCTAssertEqual(
            feed(&endpointer, level: 0.1, buffers: 24, noiseFloor: 0.004),
            [.speechStarted, .speechStopped(forced: true)])
        XCTAssertFalse(endpointer.isSpeaking)
        // 音が続いていれば（実発話の長広舌）すぐ次のセグメントとして拾い直す
        XCTAssertEqual(feed(&endpointer, level: 0.1, buffers: 3, noiseFloor: 0.004), [.speechStarted])
    }

    // MARK: - リセット

    /// STT 再接続時の仕切り直し。進行中のセグメントは破棄され、終端イベントも出ない
    func testResetDiscardsInProgressSegment() {
        var endpointer = ClientSpeechEndpointer()
        XCTAssertEqual(feed(&endpointer, level: 0.1, buffers: 3, noiseFloor: 0.004), [.speechStarted])
        endpointer.reset()
        XCTAssertFalse(endpointer.isSpeaking)
        // 言い直してもらえば新しいセグメントとして始まる
        XCTAssertEqual(feed(&endpointer, level: 0.1, buffers: 3, noiseFloor: 0.004), [.speechStarted])
    }

    // MARK: - SegmentLevelMeter との統合（暗騒音の共有）

    /// currentNoiseFloor は endSegment を待たずに読める（エンドポインタが毎バッファ参照する）
    func testMeterExposesCurrentNoiseFloor() {
        var meter = SegmentLevelMeter()
        XCTAssertEqual(meter.currentNoiseFloor, 0)  // 未推定
        for _ in 0..<10 { meter.record(0.006) }
        XCTAssertEqual(meter.currentNoiseFloor, 0.006, accuracy: 0.0001)
    }

    /// 読み上げ中の抑制: meter 側のフロア更新停止がそのまま効く（二重推定しない）。
    /// 回り込みでフロアが持ち上がると barge-in の閾値も上がってしまうため、
    /// 停止中に推定した低いフロアのまま、読み上げに被せた割り込みを小さめの声でも拾えること
    func testBargeInDetectionUsesSuppressedNoiseFloor() {
        var meter = SegmentLevelMeter()
        var endpointer = ClientSpeechEndpointer()
        for _ in 0..<40 { meter.record(0.004) }  // 静かな部屋
        XCTAssertEqual(meter.currentNoiseFloor, 0.004, accuracy: 0.0001)

        // 読み上げ中: フロア更新を止める。エコーキャンセル後の回り込み（閾値未満）が続く
        meter.isNoiseFloorUpdateSuppressed = true
        var events: [ClientSpeechEndpointer.Event] = []
        for _ in 0..<40 {
            meter.record(0.008)
            if let event = endpointer.record(
                level: 0.008, duration: bufferDuration, noiseFloor: meter.currentNoiseFloor)
            {
                events.append(event)
            }
        }
        XCTAssertEqual(events, [])  // 回り込み（floor 0.004 × 3 = 0.012 未満）では発火しない
        XCTAssertEqual(meter.currentNoiseFloor, 0.004, accuracy: 0.0001)  // フロアは持ち上がらない

        // 読み上げに被せて割り込む。低いフロアのままなので 0.02 でも閾値を超える
        for _ in 0..<3 {
            meter.record(0.02)
            if let event = endpointer.record(
                level: 0.02, duration: bufferDuration, noiseFloor: meter.currentNoiseFloor)
            {
                events.append(event)
            }
        }
        XCTAssertEqual(events, [.speechStarted])
    }
}
