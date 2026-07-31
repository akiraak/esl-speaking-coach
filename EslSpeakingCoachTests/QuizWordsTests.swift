import XCTest

@testable import EslSpeakingCoach

/// 単語クイズの出題選択（docs/plans/word-quiz-mode.md）。
/// 入力は練習済みの語（`ChatHistoryStore.recentWords`）と出題済みセッションの
/// `topicTitle`（`", "` 連結。`ChatHistoryStore.quizzedTitlesAll`）。
@MainActor
final class QuizWordsTests: XCTestCase {
    // MARK: - quizPool

    /// 正規化キーで畳み、新しい方の表記を残す（単語カードのピルと同じ流儀の上限なし版）。
    func testPoolCollapsesDuplicatesKeepingNewestSpelling() {
        XCTAssertEqual(
            ChatRoomStore.quizPool(from: ["Get Around To", "resilient", " get  around to "]),
            ["Get Around To", "resilient"])
    }

    /// ピル（6 件上限）と違い全件を返す。
    func testPoolHasNoLimit() {
        let words = (1...20).map { "word\($0)" }
        XCTAssertEqual(ChatRoomStore.quizPool(from: words), words)
    }

    // MARK: - quizzedWords

    /// `", "` 連結の topicTitle を語に戻す（複数セッションぶんは平坦化する）。
    func testQuizzedWordsSplitsJoinedTitles() {
        XCTAssertEqual(
            ChatRoomStore.quizzedWords(fromTitles: ["put off, resilient", "get around to"]),
            ["put off", "resilient", "get around to"])
    }

    func testQuizzedWordsIgnoresEmptyComponents() {
        XCTAssertEqual(ChatRoomStore.quizzedWords(fromTitles: ["", "put off, "]), ["put off"])
    }

    // MARK: - unquizzedWords

    /// 出題済みの照合は正規化キー（表記ゆれを同じ語として扱う）。
    func testUnquizzedExcludesByNormalizedKey() {
        XCTAssertEqual(
            ChatRoomStore.unquizzedWords(
                pool: ["Put Off", "resilient", "get around to"],
                quizzed: ["put  off", "GET AROUND TO"]),
            ["resilient"])
    }

    // MARK: - quizWords

    /// 未出題の語を優先して選ぶ（出題済みが混ざらない）。
    func testPrefersUnquizzedWords() {
        let pool = ["a", "b", "c", "d", "e", "f", "g"]
        var rng = SeededRandomNumberGenerator(seed: 42)
        let words = ChatRoomStore.quizWords(
            pool: pool, quizzed: ["a", "b"], count: 5, using: &rng)
        XCTAssertEqual(words.count, 5)
        XCTAssertEqual(Set(words), Set(["c", "d", "e", "f", "g"]))
    }

    /// 未出題が count 未満なら出題済みから補充してクイズの長さを揃える。
    func testFillsFromQuizzedWhenUnquizzedRunsShort() {
        let pool = ["a", "b", "c", "d"]
        var rng = SeededRandomNumberGenerator(seed: 7)
        let words = ChatRoomStore.quizWords(
            pool: pool, quizzed: ["a", "b", "c"], count: 3, using: &rng)
        XCTAssertEqual(words.count, 3)
        // 未出題の d は必ず入り、残り 2 語は出題済みから
        XCTAssertEqual(words.first, "d")
        XCTAssertTrue(Set(words.dropFirst()).isSubset(of: ["a", "b", "c"]))
    }

    /// 全語出題済みなら全語からのフォールバック（ボタンが「何も起きない」体験を避ける）。
    func testFallsBackToWholePoolWhenAllQuizzed() {
        let pool = ["a", "b", "c"]
        var rng = SeededRandomNumberGenerator(seed: 1)
        let words = ChatRoomStore.quizWords(
            pool: pool, quizzed: ["a", "b", "c"], count: 2, using: &rng)
        XCTAssertEqual(words.count, 2)
        XCTAssertTrue(Set(words).isSubset(of: Set(pool)))
    }

    /// 同じシードなら同じ選択（決定的であること = RNG が注入できていること）。
    func testDeterministicWithSeededRNG() {
        let pool = (1...10).map { "word\($0)" }
        var first = SeededRandomNumberGenerator(seed: 42)
        var second = SeededRandomNumberGenerator(seed: 42)
        XCTAssertEqual(
            ChatRoomStore.quizWords(pool: pool, quizzed: [], count: 5, using: &first),
            ChatRoomStore.quizWords(pool: pool, quizzed: [], count: 5, using: &second))
    }

    /// 母集団が count 未満なら全語（重複させてまで 5 語にしない）。
    func testReturnsWholePoolWhenSmallerThanCount() {
        var rng = SeededRandomNumberGenerator(seed: 3)
        let words = ChatRoomStore.quizWords(
            pool: ["a", "b"], quizzed: [], count: 5, using: &rng)
        XCTAssertEqual(Set(words), Set(["a", "b"]))
        XCTAssertEqual(words.count, 2)
    }

    /// 練習済み 0 語なら空（カード側でボタンを無効化するが、二重に安全に）。
    func testEmptyPoolReturnsEmpty() {
        var rng = SeededRandomNumberGenerator(seed: 1)
        XCTAssertEqual(
            ChatRoomStore.quizWords(pool: [], quizzed: [], count: 5, using: &rng), [])
    }
}
