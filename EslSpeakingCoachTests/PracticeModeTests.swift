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
}
