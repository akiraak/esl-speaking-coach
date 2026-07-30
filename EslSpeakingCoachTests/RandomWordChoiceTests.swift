import XCTest

@testable import EslSpeakingCoach

/// ランダム出題の未練習語の除外と選択（docs/plans/wordbook-random-word.md）。
/// 入力は単語帳の全語（`WordBookClient.fetchAllWords`）と練習済みの語
/// （`ChatHistoryStore.practicedWordsAll`）。
@MainActor
final class RandomWordChoiceTests: XCTestCase {
    private func entry(_ word: String) -> WordBookEntry {
        WordBookEntry(word: word, meaning: nil, partOfSpeech: nil, cefrLevel: nil)
    }

    // MARK: - unpracticedWords

    /// 練習済みの語を除き、単語帳の並び順は保つ。
    func testExcludesPracticedWords() {
        let all = [entry("put off"), entry("resilient"), entry("get around to")]
        XCTAssertEqual(
            ChatRoomStore.unpracticedWords(all: all, practiced: ["resilient"]).map(\.word),
            ["put off", "get around to"])
    }

    /// 照合は正規化キー（大文字小文字・空白の表記ゆれを同じ語として扱う）。
    /// 練習語は手入力もあるため単語帳側と表記が揃わないことがある。
    func testExcludesByNormalizedKey() {
        let all = [entry("get around to"), entry("resilient")]
        XCTAssertEqual(
            ChatRoomStore.unpracticedWords(
                all: all, practiced: [" Get  Around To ", "RESILIENT"]).map(\.word),
            [])
    }

    /// 練習済みが無ければ全語が未練習。
    func testAllUnpracticedWhenNothingPracticed() {
        let all = [entry("a"), entry("b")]
        XCTAssertEqual(
            ChatRoomStore.unpracticedWords(all: all, practiced: []).map(\.word), ["a", "b"])
    }

    // MARK: - randomWordChoice

    /// 未練習の語があればそこから選ぶ（フォールバックしない）。seeded RNG で選択を固定する。
    func testChoosesFromUnpracticedDeterministically() throws {
        let all = [entry("a"), entry("b"), entry("c"), entry("d")]
        let unpracticed = [entry("b"), entry("d")]
        var first = SeededRandomNumberGenerator(seed: 42)
        var second = SeededRandomNumberGenerator(seed: 42)
        let choice = try XCTUnwrap(
            ChatRoomStore.randomWordChoice(unpracticed: unpracticed, all: all, using: &first))
        XCTAssertFalse(choice.isFallback)
        XCTAssertTrue(["b", "d"].contains(choice.entry.word))
        // 同じシードなら同じ語（決定的であること = RNG が注入できていること）
        let repeated = try XCTUnwrap(
            ChatRoomStore.randomWordChoice(unpracticed: unpracticed, all: all, using: &second))
        XCTAssertEqual(choice.entry, repeated.entry)
    }

    /// 全語練習済みなら全語からのフォールバック（isFallback = true）。
    func testFallsBackToAllWordsWhenNoneUnpracticed() throws {
        let all = [entry("a"), entry("b")]
        var rng = SeededRandomNumberGenerator(seed: 7)
        let choice = try XCTUnwrap(
            ChatRoomStore.randomWordChoice(unpracticed: [], all: all, using: &rng))
        XCTAssertTrue(choice.isFallback)
        XCTAssertTrue(["a", "b"].contains(choice.entry.word))
    }

    /// 単語帳が空のときだけ nil（呼び出し側でアラートにする）。
    func testReturnsNilWhenWordBookIsEmpty() {
        var rng = SeededRandomNumberGenerator(seed: 1)
        XCTAssertNil(ChatRoomStore.randomWordChoice(unpracticed: [], all: [], using: &rng))
    }
}
