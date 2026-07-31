import XCTest
@testable import EslSpeakingCoach

final class PracticeModeTests: XCTestCase {
    /// 永続化した値の往復（UserDefaults / SwiftData に rawValue のまま保存する）。
    func testRawValueRoundTrip() {
        for mode in PracticeMode.allCases {
            XCTAssertEqual(PracticeMode(rawValue: mode.rawValue), mode)
            XCTAssertEqual(PracticeMode(storedValue: mode.rawValue), mode)
        }
        // 値そのものは保存済みデータの意味を変えないよう固定
        XCTAssertEqual(PracticeMode.conversation.rawValue, "conversation")
        XCTAssertEqual(PracticeMode.word.rawValue, "word")
        XCTAssertEqual(PracticeMode.quiz.rawValue, "quiz")
    }

    /// 未保存（初回起動）・未知の値は会話モードへ倒す。
    func testStoredValueFallsBackToConversation() {
        XCTAssertEqual(PracticeMode(storedValue: nil), .conversation)
        XCTAssertEqual(PracticeMode(storedValue: ""), .conversation)
        XCTAssertEqual(PracticeMode(storedValue: "phrase"), .conversation)
    }

    /// enum のケースとしては quiz も残す（保存済みレコードの復元・セッション種別に使い続ける）。
    func testAllCasesOrder() {
        XCTAssertEqual(PracticeMode.allCases, [.conversation, .word, .quiz])
    }

    /// ヘッダのピルの選択肢は会話 / 単語の 2 択（クイズは単語カード内の導線。
    /// docs/plans/archive/quiz-in-word-mode.md）。
    func testSelectableModes() {
        XCTAssertEqual(PracticeMode.selectableModes, [.conversation, .word])
    }

    /// 起動時の UI モードの復元は quiz を word へ正規化する（クイズが単語モード配下になったため。
    /// UserDefaults に旧バージョンの quiz が残った端末は単語モードで起動する）。
    /// 保存済みセッションの復元に使う `PracticeMode(storedValue:)` は正規化しない。
    @MainActor
    func testRestoredPracticeModeNormalizesQuizToWord() {
        XCTAssertEqual(ChatRoomStore.restoredPracticeMode(storedValue: "quiz"), .word)
        XCTAssertEqual(ChatRoomStore.restoredPracticeMode(storedValue: "word"), .word)
        XCTAssertEqual(
            ChatRoomStore.restoredPracticeMode(storedValue: "conversation"), .conversation)
        XCTAssertEqual(ChatRoomStore.restoredPracticeMode(storedValue: nil), .conversation)
        XCTAssertEqual(ChatRoomStore.restoredPracticeMode(storedValue: "phrase"), .conversation)
        // セッション種別の復元は quiz のまま（既存レコードを conversation に化けさせない）
        XCTAssertEqual(PracticeMode(storedValue: "quiz"), .quiz)
    }

    /// セッション文言（終了ボタン・確認アラート）はセッション中・エラー再開待ちのあいだ
    /// セッション種別基準（クイズ中の終了ボタンを「このクイズを終了」に保つ）。
    @MainActor
    func testSessionWordingMode() {
        XCTAssertEqual(
            ChatRoomStore.sessionWordingMode(
                isSessionInProgress: true, activeSessionMode: .quiz, practiceMode: .word),
            .quiz)
        XCTAssertEqual(
            ChatRoomStore.sessionWordingMode(
                isSessionInProgress: false, activeSessionMode: .quiz, practiceMode: .word),
            .word)
    }

    /// 単語モードだけ終了ボタンで終わる。会話は goodbye、クイズは全語出題後の締め
    /// （と goodbye）で [end] が出て自動終了する。
    func testEndsOnGoodbyePerMode() {
        XCTAssertTrue(PracticeMode.conversation.endsOnGoodbye)
        XCTAssertFalse(PracticeMode.word.endsOnGoodbye)
        XCTAssertTrue(PracticeMode.quiz.endsOnGoodbye)
    }

    func testOpeningControlKey() {
        XCTAssertEqual(PracticeMode.conversation.openingControlKey, "New topic")
        XCTAssertEqual(PracticeMode.word.openingControlKey, "New word")
        XCTAssertEqual(PracticeMode.quiz.openingControlKey, "Quiz words")
    }

    /// 会話用の system prompt は 1 文字も変えない（プロンプトキャッシュを作り直さないため）。
    func testSystemPromptPerMode() {
        XCTAssertEqual(PracticeMode.conversation.systemPrompt, CoachSystemPrompt.text)
        XCTAssertEqual(PracticeMode.word.systemPrompt, WordCoachSystemPrompt.text)
        XCTAssertEqual(PracticeMode.quiz.systemPrompt, QuizCoachSystemPrompt.text)
        XCTAssertNotEqual(PracticeMode.conversation.systemPrompt, PracticeMode.word.systemPrompt)
        XCTAssertNotEqual(PracticeMode.word.systemPrompt, PracticeMode.quiz.systemPrompt)
    }

    /// 単語モードの system prompt が守るべき前提（キャラの立ち位置と終了の扱い）。
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

    /// クイズモードの system prompt が守るべき前提（docs/plans/word-quiz-mode.md）。
    func testQuizSystemPromptContract() {
        let text = QuizCoachSystemPrompt.text
        // 出力形式は他モードと同一（ScriptStreamChunker / TTS を変えないための前提）
        XCTAssertTrue(text.contains("\"Chobi: \" or \"Naruko: \""))
        // 出題語は制御メッセージで渡す（プロンプトに可変要素を埋め込まない）
        XCTAssertTrue(text.contains("[Quiz words: put off, resilient, get around to]"))
        // 全語出題後（と学習者の明確な goodbye）に [end] で自動終了する
        XCTAssertTrue(text.contains("[end]"))
    }

    /// 単語・クイズモードは記憶ノートを使わない（開始時の注入も終了時の更新もしない）。
    func testOnlyConversationUsesMemoryNote() {
        XCTAssertTrue(PracticeMode.conversation.usesMemoryNote)
        XCTAssertFalse(PracticeMode.word.usesMemoryNote)
        XCTAssertFalse(PracticeMode.quiz.usesMemoryNote)
    }

    /// フィードバック生成の 1 行目（system prompt は共通のまま見出しだけ変える）。
    func testFeedbackTopicLabel() {
        XCTAssertEqual(PracticeMode.conversation.feedbackTopicLabel, "Topic")
        XCTAssertEqual(PracticeMode.word.feedbackTopicLabel, "Practice word")
        XCTAssertEqual(PracticeMode.quiz.feedbackTopicLabel, "Quiz words")
    }

    /// 画面文言のモード分岐（三項演算子で持たず PracticeMode に寄せたもの）。
    func testUIWordingPerMode() {
        XCTAssertEqual(PracticeMode.conversation.endSessionButtonTitle, "このトピックを終了")
        XCTAssertEqual(PracticeMode.word.endSessionButtonTitle, "この単語を終了")
        XCTAssertEqual(PracticeMode.quiz.endSessionButtonTitle, "このクイズを終了")
        XCTAssertEqual(PracticeMode.quiz.idlePrompt, "カードからクイズを始めてスタート")
        XCTAssertEqual(PracticeMode.quiz.topicCardTitle, "🎯 単語クイズ")
        XCTAssertNil(PracticeMode.conversation.sessionListMarker)
        XCTAssertEqual(PracticeMode.word.sessionListMarker, "📖")
        XCTAssertEqual(PracticeMode.quiz.sessionListMarker, "🎯")
    }
}
