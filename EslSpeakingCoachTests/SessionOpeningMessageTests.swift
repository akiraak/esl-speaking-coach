import XCTest
@testable import EslSpeakingCoach

/// セッション開始・エラー再開の履歴先頭に置く制御メッセージの合成
/// （[Memory: ...] + [New topic: X]。docs/plans/character-memory.md）。
final class SessionOpeningMessageTests: XCTestCase {
    func testComposeWithMemoryNoteJoinsIntoSingleMessage() {
        let message = SessionOpeningMessage.compose(
            topic: "Free talk", memoryNote: "About the learner\n- Name is Akira.")
        XCTAssertEqual(
            message,
            "[Memory: About the learner\n- Name is Akira.]\n[New topic: Free talk]")
    }

    /// 記憶が空の初回は Memory 部を省略する。
    func testComposeWithoutMemoryNoteOmitsMemoryPart() {
        XCTAssertEqual(
            SessionOpeningMessage.compose(topic: "Free talk", memoryNote: nil),
            "[New topic: Free talk]")
        XCTAssertEqual(
            SessionOpeningMessage.compose(topic: "Free talk", memoryNote: ""),
            "[New topic: Free talk]")
        XCTAssertEqual(
            SessionOpeningMessage.compose(topic: "Free talk", memoryNote: "  \n"),
            "[New topic: Free talk]")
    }

    func testComposeTrimsMemoryNote() {
        XCTAssertEqual(
            SessionOpeningMessage.compose(topic: "Free talk", memoryNote: "\n- Likes ramen. \n"),
            "[Memory: - Likes ramen.]\n[New topic: Free talk]")
    }

    // MARK: - 単語モード（docs/specs/word-practice.md）

    /// 練習語は [New word: X] で渡す。
    func testComposeWordModeUsesNewWordKey() {
        XCTAssertEqual(
            SessionOpeningMessage.compose(mode: .word, topic: "get around to", memoryNote: nil),
            "[New word: get around to]")
    }

    /// 単語モードには記憶ノートを混ぜない（ノートは 1 語の練習に効かず先頭が長くなるだけ）。
    func testComposeWordModeOmitsMemoryNote() {
        XCTAssertEqual(
            SessionOpeningMessage.compose(
                mode: .word, topic: "get around to",
                memoryNote: "About the learner\n- Name is Akira."),
            "[New word: get around to]")
    }

    // MARK: - クイズモード（docs/plans/word-quiz-mode.md）

    /// 出題語は `", "` 連結のまま [Quiz words: X, Y] の 1 行で渡す。
    func testComposeQuizModeUsesQuizWordsKey() {
        XCTAssertEqual(
            SessionOpeningMessage.compose(
                mode: .quiz, topic: "put off, resilient", memoryNote: nil),
            "[Quiz words: put off, resilient]")
    }

    /// クイズモードにも記憶ノートを混ぜない（単語モードと同じ理由）。
    func testComposeQuizModeOmitsMemoryNote() {
        XCTAssertEqual(
            SessionOpeningMessage.compose(
                mode: .quiz, topic: "put off, resilient",
                memoryNote: "About the learner\n- Name is Akira."),
            "[Quiz words: put off, resilient]")
    }

    /// mode 省略時は従来どおり会話モード（既存の呼び出しの意味を変えない）。
    func testComposeDefaultsToConversationMode() {
        XCTAssertEqual(
            SessionOpeningMessage.compose(topic: "Free talk", memoryNote: nil),
            SessionOpeningMessage.compose(mode: .conversation, topic: "Free talk", memoryNote: nil))
    }

    // MARK: - 学習者ファースト（トピックを渡さない開始）

    /// 記憶ノートだけを積む。[New topic: ...] が無いので AI の開始ターンは起きない
    /// （docs/plans/learner-first-topic.md）。
    func testComposeMemoryOnlyKeepsMemoryPart() {
        XCTAssertEqual(
            SessionOpeningMessage.composeMemoryOnly(memoryNote: "- Likes ramen."),
            "[Memory: - Likes ramen.]")
    }

    func testComposeMemoryOnlyTrimsMemoryNote() {
        XCTAssertEqual(
            SessionOpeningMessage.composeMemoryOnly(memoryNote: "\n- Likes ramen. \n"),
            "[Memory: - Likes ramen.]")
    }

    /// ノートが空なら何も積まない = 履歴は学習者の第一声から始まる。
    func testComposeMemoryOnlyReturnsNilWithoutMemoryNote() {
        XCTAssertNil(SessionOpeningMessage.composeMemoryOnly(memoryNote: nil))
        XCTAssertNil(SessionOpeningMessage.composeMemoryOnly(memoryNote: ""))
        XCTAssertNil(SessionOpeningMessage.composeMemoryOnly(memoryNote: "  \n"))
    }
}
