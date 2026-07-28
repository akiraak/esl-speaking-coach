import XCTest

@testable import EslSpeakingCoach

/// フィードバックの途切れ調査で使うスニペット整形
/// （docs/plans/feedback-truncated.md Phase 1）。
/// ログが 1 行に収まること・容疑者の不可視文字が見えること・
/// 長い応答でも先頭と末尾の両方が残ることを見る。
final class DiagnosticsSnippetTests: XCTestCase {
    /// 上限内ならそのまま。
    func testShortTextIsUnchanged() {
        XCTAssertEqual(DiagnosticsSnippet.make("{\"summary\":\"よくできました\"}", limit: 100),
                       "{\"summary\":\"よくできました\"}")
    }

    /// 改行系は可視化する（そのまま書くとログが複数行に割れて時系列が読めなくなる）。
    func testEscapesNewlines() {
        XCTAssertEqual(DiagnosticsSnippet.make("a\nb\r\nc", limit: 100), "a\\nb\\r\\nc")
    }

    /// bytes.lines が行を切る不可視文字（VT/FF/NEL/LS/PS）も見える形にする。
    /// これが生の応答に混ざっていること自体が H1 の証拠になる。
    func testEscapesUnicodeLineBreaks() {
        let text = "あ\u{0B}い\u{0C}う\u{85}え\u{2028}お\u{2029}か"
        XCTAssertEqual(
            DiagnosticsSnippet.make(text, limit: 200),
            "あ\\u000bい\\u000cう\\u0085え\\u2028お\\u2029か")
    }

    /// 上限超過は中略する。先頭（壊れ方）と末尾（閉じ括弧の有無）の両方を残す。
    func testTruncatesKeepingHeadAndTail() {
        let text = String(repeating: "a", count: 100) + "END"
        let snippet = DiagnosticsSnippet.make(text, limit: 30)
        XCTAssertTrue(snippet.hasPrefix("aaaaaaaaaaaaaaaaaaaa…"), snippet)
        XCTAssertTrue(snippet.hasSuffix("END"), snippet)
        XCTAssertTrue(snippet.contains("全 103 字"), snippet)
    }

    /// エスケープ後の長さで判定する（改行だらけの応答でも上限が効く）。
    func testTruncationCountsEscapedLength() {
        let snippet = DiagnosticsSnippet.make(String(repeating: "\n", count: 50), limit: 30)
        XCTAssertTrue(snippet.contains("全 100 字"), snippet)
    }

    func testEmptyText() {
        XCTAssertEqual(DiagnosticsSnippet.make("", limit: 100), "")
    }
}
