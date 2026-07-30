import XCTest

@testable import EslSpeakingCoach

/// 単語カードに出す単語帳の集計と表示文言（docs/plans/word-card-counts.md）。
/// 「未練習」の定義はランダム出題（`unpracticedWords`）と同一であること。
@MainActor
final class WordBookTallyTests: XCTestCase {
    private func entry(_ word: String) -> WordBookEntry {
        WordBookEntry(word: word, meaning: nil, partOfSpeech: nil, cefrLevel: nil)
    }

    // MARK: - wordBookTally

    /// 練習済みの語を除いた残りが未練習（照合は正規化キーで表記ゆれを吸収する）。
    func testCountsUnpracticedExcludingPracticed() {
        let all = [entry("put off"), entry("resilient"), entry("get around to")]
        let tally = ChatRoomStore.wordBookTally(
            all: all, practiced: [" RESILIENT ", "Get  Around To"])
        XCTAssertEqual(tally.total, 3)
        XCTAssertEqual(tally.unpracticed, 1)
    }

    /// 全語練習済みなら未練習 0。
    func testAllPracticedYieldsZeroUnpracticed() {
        let all = [entry("a"), entry("b")]
        let tally = ChatRoomStore.wordBookTally(all: all, practiced: ["a", "b"])
        XCTAssertEqual(tally.total, 2)
        XCTAssertEqual(tally.unpracticed, 0)
    }

    /// 手入力で練習した語（単語帳に無い）は集計に影響しない（母集団は常に単語帳側）。
    func testPracticedWordsNotInWordBookDoNotAffectTally() {
        let all = [entry("resilient")]
        let tally = ChatRoomStore.wordBookTally(all: all, practiced: ["handmade word"])
        XCTAssertEqual(tally.total, 1)
        XCTAssertEqual(tally.unpracticed, 1)
    }

    // MARK: - wordBookTallyLabel

    /// `5/100 5%` 形式（練習済み/総数 パーセント・未練習数）。
    func testLabelFormat() {
        XCTAssertEqual(
            ChatRoomStore.wordBookTallyLabel(total: 100, unpracticed: 95),
            "練習済み 5/100語 5%・未練習 95語")
    }

    /// パーセントは切り捨て（199/200 = 99.5% → 99%。未練習が残るうちは 100% にしない）。
    func testPercentIsFloored() {
        XCTAssertEqual(
            ChatRoomStore.wordBookTallyLabel(total: 200, unpracticed: 1),
            "練習済み 199/200語 99%・未練習 1語")
    }

    /// 全語練習済みのときだけ 100%（未練習 0 語はそのまま表示する）。
    func testAllPracticedShows100Percent() {
        XCTAssertEqual(
            ChatRoomStore.wordBookTallyLabel(total: 42, unpracticed: 0),
            "練習済み 42/42語 100%・未練習 0語")
    }

    /// 総数 0 は nil（行ごと非表示。0 除算も起きない）。
    func testEmptyWordBookHidesLabel() {
        XCTAssertNil(ChatRoomStore.wordBookTallyLabel(total: 0, unpracticed: 0))
    }
}
