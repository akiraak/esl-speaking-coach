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
    }

    /// 未保存（初回起動）・未知の値は会話モードへ倒す。
    func testStoredValueFallsBackToConversation() {
        XCTAssertEqual(PracticeMode(storedValue: nil), .conversation)
        XCTAssertEqual(PracticeMode(storedValue: ""), .conversation)
        XCTAssertEqual(PracticeMode(storedValue: "phrase"), .conversation)
    }

    func testToggleSwapsBetweenTwoModes() {
        XCTAssertEqual(PracticeMode.conversation.toggled, .word)
        XCTAssertEqual(PracticeMode.word.toggled, .conversation)
    }

    /// 単語モードは終了ボタンだけで終わる（goodbye の [end] では終わらせない）。
    func testOnlyConversationEndsOnGoodbye() {
        XCTAssertTrue(PracticeMode.conversation.endsOnGoodbye)
        XCTAssertFalse(PracticeMode.word.endsOnGoodbye)
    }

    func testOpeningControlKey() {
        XCTAssertEqual(PracticeMode.conversation.openingControlKey, "New topic")
        XCTAssertEqual(PracticeMode.word.openingControlKey, "New word")
    }

    /// 会話用の system prompt は 1 文字も変えない（プロンプトキャッシュを作り直さないため）。
    func testSystemPromptPerMode() {
        XCTAssertEqual(PracticeMode.conversation.systemPrompt, CoachSystemPrompt.text)
        XCTAssertEqual(PracticeMode.word.systemPrompt, WordCoachSystemPrompt.text)
        XCTAssertNotEqual(PracticeMode.conversation.systemPrompt, PracticeMode.word.systemPrompt)
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

    /// 単語モードは記憶ノートを使わない（開始時の注入も終了時の更新もしない）。
    func testOnlyConversationUsesMemoryNote() {
        XCTAssertTrue(PracticeMode.conversation.usesMemoryNote)
        XCTAssertFalse(PracticeMode.word.usesMemoryNote)
    }

    /// フィードバック生成の 1 行目（system prompt は共通のまま見出しだけ変える）。
    func testFeedbackTopicLabel() {
        XCTAssertEqual(PracticeMode.conversation.feedbackTopicLabel, "Topic")
        XCTAssertEqual(PracticeMode.word.feedbackTopicLabel, "Practice word")
    }
}
