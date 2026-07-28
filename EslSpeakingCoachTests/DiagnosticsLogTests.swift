import XCTest

@testable import EslSpeakingCoach

/// クラッシュ調査用の追記ログ（docs/plans/end-session-crash.md Phase 0）。
/// 落ちた直後でも書いた分が残っていることが要件なので、
/// 「append したら即ファイルに出ている」ことと「上限で末尾が残る」ことを見る。
final class DiagnosticsLogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL.temporaryDirectory.appending(path: "diagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeLog(_ name: String = "app.log") -> DiagnosticsLogFile {
        DiagnosticsLogFile(url: directory.appending(path: "sub/\(name)"))
    }

    /// 追記はバッファに溜めずその場で書く（abort しても残る）。
    func testAppendIsVisibleImmediately() {
        let log = makeLog()
        log.open()
        log.append("end: ボタン押下")
        XCTAssertTrue(log.text().contains("end: ボタン押下"))
    }

    /// 親ディレクトリが無くても開ける。
    func testOpenCreatesIntermediateDirectories() {
        let log = makeLog()
        XCTAssertGreaterThanOrEqual(log.open(), 0)
    }

    /// 書いた順に並ぶ（時系列で追えることが調査の前提）。
    func testKeepsAppendOrder() {
        let log = makeLog()
        log.open()
        for index in 0..<50 {
            log.append("line \(index)")
        }
        let lines = log.text().split(separator: "\n")
        XCTAssertEqual(lines.count, 50)
        XCTAssertTrue(lines.first?.hasSuffix("line 0") ?? false)
        XCTAssertTrue(lines.last?.hasSuffix("line 49") ?? false)
    }

    /// 行頭に時刻が付く（落ちるまでの間隔を読むため）。
    func testPrefixesTimestamp() {
        let log = makeLog()
        log.open()
        log.append("stop: 完了", at: Date(timeIntervalSince1970: 0))
        let text = log.text()
        // 端末のタイムゾーンに依存しないよう書式だけ見る（MM-dd HH:mm:ss.SSS）
        XCTAssertNotNil(
            text.range(of: #"^\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} "#, options: .regularExpression),
            "時刻の前置が無い: \(text)")
        XCTAssertTrue(text.hasSuffix("stop: 完了\n"))
    }

    /// 上限を超えたら古い方から捨て、直近（＝落ちる直前）を残す。
    func testTruncatesOldestLinesOnOpen() throws {
        let url = directory.appending(path: "sub/app.log")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = (0..<5000).map { "古い行 \($0)" }.joined(separator: "\n") + "\n最後の古い行\n"
        try Data(old.utf8).write(to: url)

        let log = DiagnosticsLogFile(url: url)
        log.open(maxBytes: 4096, keepBytes: 2048)
        log.append("再起動後の行")

        let text = log.text()
        XCTAssertLessThan(text.utf8.count, 4096 + 512)
        XCTAssertFalse(text.contains("古い行 0"), "古い方が残っている")
        XCTAssertTrue(text.contains("最後の古い行"), "直近が消えている")
        XCTAssertTrue(text.contains("再起動後の行"))
        XCTAssertTrue(text.contains("切り詰め"))
    }

    /// 切り詰めは行の途中で切らない。
    func testTruncationKeepsWholeLines() throws {
        let url = directory.appending(path: "sub/app.log")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = (0..<2000).map { "abcdefghij \($0)" }.joined(separator: "\n") + "\n"
        try Data(old.utf8).write(to: url)

        let log = DiagnosticsLogFile(url: url)
        log.open(maxBytes: 1024, keepBytes: 512)
        let lines = log.text().split(separator: "\n").dropFirst()  // 1 行目は切り詰め通知
        for line in lines {
            XCTAssertTrue(line.hasPrefix("abcdefghij "), "行の途中で切れている: \(line)")
        }
    }

    /// 上限内なら何も捨てない。
    func testKeepsEverythingUnderLimit() {
        let log = makeLog()
        log.open(maxBytes: 4096, keepBytes: 2048)
        log.append("最初の行")
        XCTAssertFalse(log.text().contains("切り詰め"))
        XCTAssertTrue(log.text().contains("最初の行"))
    }

    /// クリアしても書き続けられる（fd を開いたまま使い回す）。
    func testClearEmptiesFileAndKeepsWriting() {
        let log = makeLog()
        log.open()
        log.append("消える行")
        log.clear()
        XCTAssertFalse(log.text().contains("消える行"))
        log.append("消えない行")
        XCTAssertTrue(log.text().contains("消えない行"))
    }

    /// 二重 open で fd を作り直さない（既存の追記位置を壊さない）。
    func testOpenIsIdempotent() {
        let log = makeLog()
        let first = log.open()
        XCTAssertEqual(log.open(), first)
        log.append("行")
        XCTAssertTrue(log.text().contains("行"))
    }

    /// open 前の append は落とすだけで、クラッシュはしない。
    func testAppendBeforeOpenIsIgnored() {
        let log = makeLog()
        log.append("open していない")
        XCTAssertEqual(log.text(), "")
    }
}
