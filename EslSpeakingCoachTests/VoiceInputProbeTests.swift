import XCTest

@testable import EslSpeakingCoach

/// いつでも話せる音声入力 Phase 2（実測）の診断プローブ
/// （docs/plans/always-on-voice-input.md）。**判断に使う数字が 1 行に正しく畳まれること**を固定する。
final class VoiceInputProbeTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date {
        origin.addingTimeInterval(seconds)
    }

    // MARK: - SegmentTranscriptProbe（実測 1: partial delta の到達）

    /// commit（発話終端）より前に届いた delta と後に届いた delta を分けて数える。
    /// ここが分かれていないと「読み上げ中の割り込みを partial で確定できるか」を判断できない
    func testCountsDeltasBeforeAndAfterCommit() {
        var probe = SegmentTranscriptProbe(startedAt: origin)
        probe.recordPartial("I", at: at(0.6))
        probe.recordPartial("I went", at: at(0.9))
        probe.recordCommit(at: at(2.0))
        probe.recordPartial("I went to the park", at: at(2.4))

        XCTAssertEqual(probe.deltas.map(\.isBeforeCommit), [true, true, false])
        XCTAssertEqual(probe.deltas.map(\.wordCount), [1, 2, 5])
        let line = probe.summaryLine(final: "I went to the park.", at: at(2.5))
        XCTAssertTrue(line.contains("発話 2.00s"), line)
        XCTAssertTrue(line.contains("delta 3 件（初回 +0.60s"), line)
        XCTAssertTrue(line.contains("2 語 +0.90s"), line)
        XCTAssertTrue(line.contains("commit 前 2 件（2 語）・後 1 件"), line)
        XCTAssertTrue(line.contains("commit→final 0.50s"), line)
    }

    /// delta が 1 件も届かない（＝確定でまとめて来る）実装だった場合。
    /// この行が出たら回収ウィンドウ③（読み上げ直後の言い直し）は成立しない
    func testReportsMissingDeltas() {
        var probe = SegmentTranscriptProbe(startedAt: origin)
        probe.recordCommit(at: at(1.5))
        let line = probe.summaryLine(final: "hello", at: at(2.0))
        XCTAssertTrue(line.contains("delta なし"), line)
    }

    /// 語数が 2 に届かないまま終わったら「未到達」と残す（1 語だけの partial では割り込みを確定しない）
    func testReportsTwoWordsNotReached() {
        var probe = SegmentTranscriptProbe(startedAt: origin)
        probe.recordPartial("hello", at: at(0.4))
        probe.recordCommit(at: at(1.0))
        let line = probe.summaryLine(final: "hello", at: at(1.2))
        XCTAssertTrue(line.contains("2 語 未到達"), line)
    }

    /// commit を待たずに畳んだ場合（ゲートが閉じた・STT が切れた）は commit なしと分かる形で残す
    func testSummaryWithoutCommit() {
        var probe = SegmentTranscriptProbe(startedAt: origin)
        probe.recordPartial("I was", at: at(0.5))
        let line = probe.summaryLine(final: nil, at: at(1.0))
        XCTAssertTrue(line.contains("発話 1.00s"), line)
        XCTAssertTrue(line.contains("commit なし"), line)
        XCTAssertTrue(line.contains("final なし"), line)
    }

    /// commit は最初の 1 回だけ効く（2 度目の speechStopped で起点がずれない）
    func testCommitIsRecordedOnce() {
        var probe = SegmentTranscriptProbe(startedAt: origin)
        probe.recordCommit(at: at(1.0))
        probe.recordCommit(at: at(3.0))
        XCTAssertEqual(probe.committedAt, at(1.0))
    }

    // MARK: - 句読点（実測 2）

    /// 句読点が出る STT なら `TurnCommitGrace` の記号判定が使える
    func testPunctuationNoteWithTerminatorAndComma() {
        XCTAssertEqual(
            SegmentTranscriptProbe.punctuationNote(for: "I went to the park, and it was nice."),
            "末尾\".\"・読点あり")
    }

    /// live の STT が句読点を出さない場合はこの形になり、猶予の出し分けは末尾語だけが頼りになる
    func testPunctuationNoteWithoutMarks() {
        XCTAssertEqual(
            SegmentTranscriptProbe.punctuationNote(for: "i went to the park and it was nice"),
            "末尾記号なし・読点なし")
    }

    func testPunctuationNoteForQuestion() {
        XCTAssertEqual(
            SegmentTranscriptProbe.punctuationNote(for: "How about you?"), "末尾\"?\"・読点なし")
    }

    func testPunctuationNoteForEmptyText() {
        XCTAssertEqual(SegmentTranscriptProbe.punctuationNote(for: ""), "末尾なし・読点なし")
    }

    /// 語数は空白区切り（連続空白・前後の空白で水増ししない）
    func testWordCountIgnoresExtraWhitespace() {
        XCTAssertEqual(SegmentTranscriptProbe.wordCount(of: "  I   went to  "), 3)
        XCTAssertEqual(SegmentTranscriptProbe.wordCount(of: "   "), 0)
    }

    // MARK: - PlaybackEchoProbe（実測 3: 読み上げ中のエコー残留）

    /// **連続**超過の最長時間が要（エンドポインタは連続 minimumSpeechDuration で発火するため）。
    /// 途切れた超過は run に積まず、合計にだけ入る
    func testTracksLongestConsecutiveRunPerThreshold() throws {
        var probe = PlaybackEchoProbe(thresholds: [0.01])
        let buffer: TimeInterval = 0.05
        // 0.10 秒超過 → 途切れ → 0.15 秒超過
        for _ in 0..<2 { probe.record(level: 0.02, duration: buffer) }
        probe.record(level: 0.001, duration: buffer)
        for _ in 0..<3 { probe.record(level: 0.02, duration: buffer) }

        let stat = try XCTUnwrap(probe.stats.first)
        XCTAssertEqual(stat.totalAbove, 0.25, accuracy: 0.001)
        XCTAssertEqual(stat.longestRun, 0.15, accuracy: 0.001)
        XCTAssertEqual(probe.duration, 0.30, accuracy: 0.001)
        XCTAssertEqual(probe.bufferCount, 6)
    }

    /// しきい値ごとに独立して集計する（0.01 は超えるが 0.05 は超えない残留、が普通に起きる）
    func testAggregatesEachThresholdIndependently() {
        var probe = PlaybackEchoProbe(thresholds: [0.01, 0.05])
        for _ in 0..<4 { probe.record(level: 0.02, duration: 0.043) }

        XCTAssertEqual(probe.stats[0].longestRun, 0.172, accuracy: 0.001)
        XCTAssertEqual(probe.stats[1].longestRun, 0)
        XCTAssertEqual(probe.stats[1].totalAbove, 0)
    }

    /// 平均・最大は全バッファから取る（しきい値に関係なく残留の大きさを見る）
    func testMeanAndPeak() {
        var probe = PlaybackEchoProbe(thresholds: [0.01])
        probe.record(level: 0.002, duration: 0.043)
        probe.record(level: 0.006, duration: 0.043)
        XCTAssertEqual(probe.mean, 0.004, accuracy: 0.0001)
        XCTAssertEqual(probe.peak, 0.006, accuracy: 0.0001)
    }

    /// 1 バッファも届いていなければ平均は 0（ゼロ除算しない）
    func testEmptyProbe() {
        let probe = PlaybackEchoProbe()
        XCTAssertEqual(probe.mean, 0)
        XCTAssertEqual(probe.bufferCount, 0)
    }

    /// 1 行にしきい値ごとの数字と、判断に要る文脈（VP・経路）が残る
    func testEchoSummaryLine() {
        var probe = PlaybackEchoProbe(thresholds: [0.01, 0.05])
        for _ in 0..<10 { probe.record(level: 0.02, duration: 0.05) }
        let line = probe.summaryLine(context: "floor 0.0030 / VP=on / 内蔵スピーカー")
        XCTAssertTrue(line.hasPrefix("probe echo: 読み上げ 0.50s"), line)
        XCTAssertTrue(line.contains("rms 平均 0.0200 最大 0.0200"), line)
        XCTAssertTrue(line.contains(">0.010 0.50s(最長 0.50s)"), line)
        XCTAssertTrue(line.contains(">0.050 0.00s(最長 0.00s)"), line)
        XCTAssertTrue(line.contains("VP=on"), line)
    }
}
