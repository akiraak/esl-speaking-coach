import XCTest
@testable import EslSpeakingCoach

/// セッションの種別（会話 / 単語 / クイズ）。UI の練習モードは `PracticeModeTests` を参照
/// （docs/plans/practice-mode-refactor.md で分離）。
final class SessionKindTests: XCTestCase {
    /// 永続化した値の往復（SwiftData `ChatSessionRecord.modeRawValue` に rawValue のまま保存する）。
    func testRawValueRoundTrip() {
        for kind in SessionKind.allCases {
            XCTAssertEqual(SessionKind(rawValue: kind.rawValue), kind)
            XCTAssertEqual(SessionKind(storedValue: kind.rawValue), kind)
        }
        // 値そのものは保存済みデータの意味を変えないよう固定
        XCTAssertEqual(SessionKind.conversation.rawValue, "conversation")
        XCTAssertEqual(SessionKind.word.rawValue, "word")
        XCTAssertEqual(SessionKind.quiz.rawValue, "quiz")
    }

    /// 未保存（種別導入前のレコード）・未知の値は会話へ倒す。quiz は quiz のまま復元する
    /// （既存レコードを化けさせない。UI モード側の quiz→word 正規化はここでは行わない）。
    func testStoredValueFallsBackToConversation() {
        XCTAssertEqual(SessionKind(storedValue: nil), .conversation)
        XCTAssertEqual(SessionKind(storedValue: ""), .conversation)
        XCTAssertEqual(SessionKind(storedValue: "phrase"), .conversation)
        XCTAssertEqual(SessionKind(storedValue: "quiz"), .quiz)
    }

    /// 単語だけ終了ボタンで終わる。会話は goodbye、クイズは全語出題後の締め
    /// （と goodbye）で [end] が出て自動終了する。
    func testEndsOnGoodbyePerKind() {
        XCTAssertTrue(SessionKind.conversation.endsOnGoodbye)
        XCTAssertFalse(SessionKind.word.endsOnGoodbye)
        XCTAssertTrue(SessionKind.quiz.endsOnGoodbye)
    }

    func testOpeningControlKey() {
        XCTAssertEqual(SessionKind.conversation.openingControlKey, "New topic")
        XCTAssertEqual(SessionKind.word.openingControlKey, "New word")
        XCTAssertEqual(SessionKind.quiz.openingControlKey, "Quiz words")
    }

    /// 会話用の system prompt は 1 文字も変えない（プロンプトキャッシュを作り直さないため）。
    func testSystemPromptPerKind() {
        XCTAssertEqual(SessionKind.conversation.systemPrompt, CoachSystemPrompt.text)
        XCTAssertEqual(SessionKind.word.systemPrompt, WordCoachSystemPrompt.text)
        XCTAssertEqual(SessionKind.quiz.systemPrompt, QuizCoachSystemPrompt.text)
        XCTAssertNotEqual(SessionKind.conversation.systemPrompt, SessionKind.word.systemPrompt)
        XCTAssertNotEqual(SessionKind.word.systemPrompt, SessionKind.quiz.systemPrompt)
    }

    /// 単語練習の system prompt が守るべき前提（キャラの立ち位置と終了の扱い）。
    func testWordSystemPromptContract() {
        let text = WordCoachSystemPrompt.text
        // 出力形式は会話モードと同一（ScriptStreamChunker / TTS を変えないための前提）
        XCTAssertTrue(text.contains("\"Chobi: \" or \"Naruko: \""))
        // 練習語は制御メッセージで渡す（プロンプトに可変要素を埋め込まない）
        XCTAssertTrue(text.contains("[New word: get around to]"))
        // 自分からは終わらせない = [end] の規定を持たない
        XCTAssertFalse(text.contains("[end]"))
        XCTAssertTrue(text.contains("Never end the session yourself."))
    }

    /// クイズの system prompt が守るべき前提（docs/plans/word-quiz-mode.md）。
    func testQuizSystemPromptContract() {
        let text = QuizCoachSystemPrompt.text
        // 出力形式は他モードと同一（ScriptStreamChunker / TTS を変えないための前提）
        XCTAssertTrue(text.contains("\"Chobi: \" or \"Naruko: \""))
        // 出題語は制御メッセージで渡す（プロンプトに可変要素を埋め込まない）
        XCTAssertTrue(text.contains("[Quiz words: put off, resilient, get around to]"))
        // 全語出題後（と学習者の明確な goodbye）に [end] で自動終了する
        XCTAssertTrue(text.contains("[end]"))
    }

    /// 単語・クイズは記憶ノートを使わない（開始時の注入も終了時の更新もしない）。
    func testOnlyConversationUsesMemoryNote() {
        XCTAssertTrue(SessionKind.conversation.usesMemoryNote)
        XCTAssertFalse(SessionKind.word.usesMemoryNote)
        XCTAssertFalse(SessionKind.quiz.usesMemoryNote)
    }

    /// フィードバック生成の 1 行目（system prompt は共通のまま見出しだけ変える）。
    func testFeedbackTopicLabel() {
        XCTAssertEqual(SessionKind.conversation.feedbackTopicLabel, "Topic")
        XCTAssertEqual(SessionKind.word.feedbackTopicLabel, "Practice word")
        XCTAssertEqual(SessionKind.quiz.feedbackTopicLabel, "Quiz words")
    }

    /// セッションに紐づく画面文言（終了ボタン・管理画面の一覧の印）。
    func testUIWordingPerKind() {
        XCTAssertEqual(SessionKind.conversation.endSessionButtonTitle, "このトピックを終了")
        XCTAssertEqual(SessionKind.word.endSessionButtonTitle, "この単語を終了")
        XCTAssertEqual(SessionKind.quiz.endSessionButtonTitle, "このクイズを終了")
        XCTAssertNil(SessionKind.conversation.sessionListMarker)
        XCTAssertEqual(SessionKind.word.sessionListMarker, "📖")
        XCTAssertEqual(SessionKind.quiz.sessionListMarker, "🎯")
    }
}
