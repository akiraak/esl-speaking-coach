import XCTest
@testable import EslSpeakingCoach

/// セッション開始・エラー再開の履歴先頭に置く制御メッセージの合成
/// （[Memory: ...] 系 3 行 + [New topic: X]。docs/plans/archive/per-character-memory.md）。
final class SessionOpeningMessageTests: XCTestCase {
    private let learnerNote = "About the learner\n- Name is Akira."

    func testComposeWithMemoryNoteJoinsIntoSingleMessage() {
        let message = SessionOpeningMessage.compose(
            topic: "Free talk", memoryNotes: MemoryNotes(learner: learnerNote))
        XCTAssertEqual(
            message,
            "[Memory: About the learner\n- Name is Akira.]\n[New topic: Free talk]")
    }

    /// 3 本そろっているときは 学習者 → Chobi → Naruko の順で 1 通にまとめる。
    func testComposeJoinsThreeNotesInOrder() {
        let message = SessionOpeningMessage.compose(
            topic: "Free talk",
            memoryNotes: MemoryNotes(
                learner: "- Name is Akira.",
                chobi: "- Adopted a kitten.",
                naruko: "- Went to karaoke."))
        XCTAssertEqual(
            message,
            """
            [Memory: - Name is Akira.]
            [Memory about Chobi: - Adopted a kitten.]
            [Memory about Naruko: - Went to karaoke.]
            [New topic: Free talk]
            """)
    }

    /// 空のノートは行ごと省略する（キャラだけ、学習者だけ、どちらもあり得る）。
    func testComposeOmitsEmptyNotesLineByLine() {
        XCTAssertEqual(
            SessionOpeningMessage.compose(
                topic: "Free talk",
                memoryNotes: MemoryNotes(learner: "- Name is Akira.", naruko: "  \n")),
            "[Memory: - Name is Akira.]\n[New topic: Free talk]")
        XCTAssertEqual(
            SessionOpeningMessage.compose(
                topic: "Free talk", memoryNotes: MemoryNotes(chobi: "- Adopted a kitten.")),
            "[Memory about Chobi: - Adopted a kitten.]\n[New topic: Free talk]")
    }

    /// 記憶が空の初回は Memory 部を省略する。
    func testComposeWithoutMemoryNoteOmitsMemoryPart() {
        for notes in [
            MemoryNotes.empty,
            MemoryNotes(learner: "", chobi: "", naruko: ""),
            MemoryNotes(learner: "  \n", chobi: "  \n", naruko: "  \n"),
        ] {
            XCTAssertEqual(
                SessionOpeningMessage.compose(topic: "Free talk", memoryNotes: notes),
                "[New topic: Free talk]")
            XCTAssertTrue(notes.isEmpty)
        }
    }

    func testComposeTrimsMemoryNote() {
        XCTAssertEqual(
            SessionOpeningMessage.compose(
                topic: "Free talk",
                memoryNotes: MemoryNotes(learner: "\n- Likes ramen. \n", chobi: " - Has a cat.\n")),
            "[Memory: - Likes ramen.]\n[Memory about Chobi: - Has a cat.]\n[New topic: Free talk]")
    }

    // MARK: - 単語モード（docs/specs/word-practice.md）

    /// 練習語は [New word: X] で渡す。
    func testComposeWordKindUsesNewWordKey() {
        XCTAssertEqual(
            SessionOpeningMessage.compose(
                kind: .word, topic: "get around to", memoryNotes: .empty),
            "[New word: get around to]")
    }

    /// 単語モードには記憶ノートを混ぜない（ノートは 1 語の練習に効かず先頭が長くなるだけ）。
    /// キャラのノートも同じく混ぜない。
    func testComposeWordKindOmitsMemoryNote() {
        XCTAssertEqual(
            SessionOpeningMessage.compose(
                kind: .word, topic: "get around to",
                memoryNotes: MemoryNotes(
                    learner: learnerNote, chobi: "- Has a cat.", naruko: "- Likes ramen.")),
            "[New word: get around to]")
    }

    // MARK: - クイズモード（docs/plans/archive/word-quiz-mode.md）

    /// 出題語は `", "` 連結のまま [Quiz words: X, Y] の 1 行で渡す。
    func testComposeQuizKindUsesQuizWordsKey() {
        XCTAssertEqual(
            SessionOpeningMessage.compose(
                kind: .quiz, topic: "put off, resilient", memoryNotes: .empty),
            "[Quiz words: put off, resilient]")
    }

    /// クイズモードにも記憶ノートを混ぜない（単語モードと同じ理由）。
    func testComposeQuizKindOmitsMemoryNote() {
        XCTAssertEqual(
            SessionOpeningMessage.compose(
                kind: .quiz, topic: "put off, resilient",
                memoryNotes: MemoryNotes(
                    learner: learnerNote, chobi: "- Has a cat.", naruko: "- Likes ramen.")),
            "[Quiz words: put off, resilient]")
    }

    /// kind 省略時は従来どおり会話（既存の呼び出しの意味を変えない）。
    func testComposeDefaultsToConversationKind() {
        XCTAssertEqual(
            SessionOpeningMessage.compose(topic: "Free talk", memoryNotes: .empty),
            SessionOpeningMessage.compose(
                kind: .conversation, topic: "Free talk", memoryNotes: .empty))
    }

    // MARK: - 学習者ファースト（トピックを渡さない開始）

    /// 記憶ノートだけを積む。[New topic: ...] が無いので AI の開始ターンは起きない
    /// （docs/plans/archive/learner-first-topic.md）。
    func testComposeMemoryOnlyKeepsMemoryPart() {
        XCTAssertEqual(
            SessionOpeningMessage.composeMemoryOnly(
                memoryNotes: MemoryNotes(learner: "- Likes ramen.", naruko: "- Went to karaoke.")),
            "[Memory: - Likes ramen.]\n[Memory about Naruko: - Went to karaoke.]")
    }

    func testComposeMemoryOnlyTrimsMemoryNote() {
        XCTAssertEqual(
            SessionOpeningMessage.composeMemoryOnly(
                memoryNotes: MemoryNotes(learner: "\n- Likes ramen. \n")),
            "[Memory: - Likes ramen.]")
    }

    /// ノートが空なら何も積まない = 履歴は学習者の第一声から始まる。
    func testComposeMemoryOnlyReturnsNilWithoutMemoryNote() {
        XCTAssertNil(SessionOpeningMessage.composeMemoryOnly(memoryNotes: .empty))
        XCTAssertNil(SessionOpeningMessage.composeMemoryOnly(
            memoryNotes: MemoryNotes(learner: "", chobi: "", naruko: "")))
        XCTAssertNil(SessionOpeningMessage.composeMemoryOnly(
            memoryNotes: MemoryNotes(learner: "  \n", chobi: "  \n", naruko: "  \n")))
    }
}
