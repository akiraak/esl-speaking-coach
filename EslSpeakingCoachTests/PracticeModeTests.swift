import XCTest
@testable import EslSpeakingCoach

/// UI の練習モード（会話 / 単語）。セッションの振る舞い・保存レコードの種別は
/// `SessionKindTests` を参照（docs/plans/practice-mode-refactor.md で分離）。
final class PracticeModeTests: XCTestCase {
    /// 永続化した値の往復（UserDefaults `chatRoomPracticeMode` に rawValue のまま保存する）。
    func testRawValueRoundTrip() {
        for mode in PracticeMode.allCases {
            XCTAssertEqual(PracticeMode(rawValue: mode.rawValue), mode)
            XCTAssertEqual(PracticeMode(storedValue: mode.rawValue), mode)
        }
        // 値そのものは保存済みデータの意味を変えないよう固定
        XCTAssertEqual(PracticeMode.conversation.rawValue, "conversation")
        XCTAssertEqual(PracticeMode.word.rawValue, "word")
    }

    /// 未保存（初回起動）・未知の値は会話モードへ倒す。
    func testStoredValueFallsBackToConversation() {
        XCTAssertEqual(PracticeMode(storedValue: nil), .conversation)
        XCTAssertEqual(PracticeMode(storedValue: ""), .conversation)
        XCTAssertEqual(PracticeMode(storedValue: "phrase"), .conversation)
    }

    /// ヘッダのピルの選択肢 = allCases は会話 / 単語の 2 択
    /// （クイズは単語カード内の導線 = セッション種別。docs/plans/archive/quiz-in-word-mode.md）。
    func testAllCasesOrder() {
        XCTAssertEqual(PracticeMode.allCases, [.conversation, .word])
    }

    /// UserDefaults に残る旧バージョンの UI モード保存値 `quiz` は単語モードへ正規化する
    /// （クイズが単語モード配下になったため。セッション種別の復元 `SessionKind(storedValue:)`
    /// は正規化しない）。
    func testStoredValueNormalizesQuizToWord() {
        XCTAssertEqual(PracticeMode(storedValue: "quiz"), .word)
    }

    /// 通常のセッション開始の既定種別は UI モードと同名（クイズだけは導線側が明示的に渡す）。
    func testDefaultSessionKind() {
        XCTAssertEqual(PracticeMode.conversation.defaultSessionKind, .conversation)
        XCTAssertEqual(PracticeMode.word.defaultSessionKind, .word)
    }

    /// セッション外の画面文言（入力バーの案内・カード見出し）。
    func testUIWordingPerMode() {
        XCTAssertEqual(PracticeMode.conversation.idlePrompt, "トピックカードから話題を選んでスタート")
        XCTAssertEqual(PracticeMode.word.idlePrompt, "カードから練習する単語を入力してスタート")
        XCTAssertEqual(PracticeMode.conversation.topicCardTitle, "📌 次のトピック")
        XCTAssertEqual(PracticeMode.word.topicCardTitle, "📖 次に練習する単語")
    }
}
