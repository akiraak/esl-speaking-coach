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
