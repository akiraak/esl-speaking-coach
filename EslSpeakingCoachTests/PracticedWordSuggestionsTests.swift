import XCTest

@testable import EslSpeakingCoach

/// 単語カードに出す「前に練習した語」の選び方（docs/plans/vocabulary-continuity.md）。
/// 入力は `ChatHistoryStore.recentWords`（新しい順の練習語）、出力は表示するピル。
@MainActor
final class PracticedWordSuggestionsTests: XCTestCase {
    /// 新しい順のまま、上限まで出す。
    func testKeepsNewestFirstOrder() {
        XCTAssertEqual(
            ChatRoomStore.practicedWordSuggestions(
                from: ["put off", "look up", "get around to"]),
            ["put off", "look up", "get around to"])
    }

    /// 同じ語を何度練習しても履歴には都度残るので、畳んで 1 件にする。
    /// 残すのは新しい方の表記（後から直した綴りが生きる）。
    func testCollapsesDuplicatesKeepingNewestSpelling() {
        XCTAssertEqual(
            ChatRoomStore.practicedWordSuggestions(
                from: ["Get around to", "look up", "get  around  to", "look up"]),
            ["Get around to", "look up"])
    }

    /// 前後の空白は落とし、空文字・空白だけの語は出さない。
    func testTrimsAndDropsBlankWords() {
        XCTAssertEqual(
            ChatRoomStore.practicedWordSuggestions(from: ["  take after ", "", "   ", "put off"]),
            ["take after", "put off"])
    }

    /// 上限は重複を畳んだ**後**の件数で数える。
    func testLimitAppliesAfterDeduplication() {
        let words = ["a", "a", "b", "b", "c", "d"]
        XCTAssertEqual(ChatRoomStore.practicedWordSuggestions(from: words, limit: 3), ["a", "b", "c"])
        XCTAssertEqual(ChatRoomStore.practicedWordSuggestions(from: words, limit: 0), [])
    }

    /// 練習履歴が無いあいだはピルを出さない（入力ボタンだけの従来どおりの見た目）。
    func testEmptyHistoryProducesNoSuggestions() {
        XCTAssertTrue(ChatRoomStore.practicedWordSuggestions(from: []).isEmpty)
    }

    /// 既定の件数（カードが縦に伸びすぎない上限）。
    func testDefaultLimit() {
        let words = (1...20).map { "word \($0)" }
        XCTAssertEqual(
            ChatRoomStore.practicedWordSuggestions(from: words).count,
            ChatRoomStore.wordSuggestionCount)
    }

    /// 大文字小文字・連続空白のゆれは同じ語として扱う。
    func testNormalizationKey() {
        XCTAssertEqual(
            ChatRoomStore.normalizedWordKey(" Get   Around  To "),
            ChatRoomStore.normalizedWordKey("get around to"))
        XCTAssertNotEqual(
            ChatRoomStore.normalizedWordKey("look up"),
            ChatRoomStore.normalizedWordKey("look up to"))
    }
}
