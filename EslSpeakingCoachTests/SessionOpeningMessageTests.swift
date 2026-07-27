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
}
