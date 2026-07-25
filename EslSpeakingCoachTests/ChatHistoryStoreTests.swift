import XCTest
@testable import EslSpeakingCoach

@MainActor
final class ChatHistoryStoreTests: XCTestCase {
    private func makeStore() throws -> ChatHistoryStore {
        ChatHistoryStore(container: try AppModelContainer.make(inMemory: true))
    }

    func testSessionRoundTrip() throws {
        let store = try makeStore()
        let sessionID = UUID()
        store.beginSession(id: sessionID, topicTitle: "Morning routines")

        let userID = UUID()
        let chobiID = UUID()
        store.appendMessage(id: userID, speaker: .user, text: "I wake up at six.")
        store.appendMessage(id: chobiID, speaker: .chobi, text: "Six?")
        // ストリーミングでテキストが伸びた
        store.updateMessageText(id: chobiID, text: "Six? That is early. What do you do first?")
        store.endActiveSession()

        let sessions = store.recentSessions(limit: 10)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].topicTitle, "Morning routines")
        XCTAssertNotNil(sessions[0].endedAt)

        let messages = store.messages(sessionID: sessionID)
        XCTAssertEqual(messages.map(\.speaker), [.user, .chobi])
        XCTAssertEqual(messages[1].text, "Six? That is early. What do you do first?")
    }

    func testFeedbackRoundTrip() throws {
        let store = try makeStore()
        let sessionID = UUID()
        store.beginSession(id: sessionID, topicTitle: "Comfort food")
        store.appendMessage(id: UUID(), speaker: .user, text: "I like ramen.")
        store.endActiveSession()

        let feedback = SessionFeedback(
            summary: "よく話せました。",
            corrections: [.init(original: "I like eat", improved: "I like eating", note: "動名詞にします")],
            tryPhrases: [.init(phrase: "comfort food", meaning: "ほっとする食べ物")])
        store.saveFeedback(sessionID: sessionID, feedback: feedback)

        XCTAssertEqual(store.feedback(sessionID: sessionID), feedback)
        XCTAssertEqual(store.sessionSummaries().first?.hasFeedback, true)
    }

    /// 前回セッション中に落ちた場合: 発話ありは最終発話時刻で閉じ、空は削除する。
    func testCloseUnfinishedSessions() throws {
        let store = try makeStore()
        store.beginSession(id: UUID(), topicTitle: "Interrupted")
        store.appendMessage(id: UUID(), speaker: .user, text: "Hello")
        store.beginSession(id: UUID(), topicTitle: "Empty crash")

        store.closeUnfinishedSessions()

        let sessions = store.recentSessions(limit: 10)
        XCTAssertEqual(sessions.map(\.topicTitle), ["Interrupted"])
        XCTAssertNotNil(sessions[0].endedAt)
    }

    func testRecentTopicTitlesKeepsLatest() throws {
        let store = try makeStore()
        for index in 0..<5 {
            store.beginSession(id: UUID(), topicTitle: "Topic \(index)")
            store.appendMessage(id: UUID(), speaker: .user, text: "hi")
            store.endActiveSession()
        }
        XCTAssertEqual(store.recentTopicTitles(limit: 3), ["Topic 2", "Topic 3", "Topic 4"])
    }

    /// 発話ゼロで終了したセッションは残さない。
    func testEmptySessionIsDiscardedOnEnd() throws {
        let store = try makeStore()
        store.beginSession(id: UUID(), topicTitle: "No talk")
        store.endActiveSession()
        XCTAssertTrue(store.recentSessions(limit: 10).isEmpty)
    }

    func testDeleteSessionCascadesMessages() throws {
        let store = try makeStore()
        let sessionID = UUID()
        store.beginSession(id: sessionID, topicTitle: "To delete")
        store.appendMessage(id: UUID(), speaker: .user, text: "bye")
        store.endActiveSession()

        store.deleteSession(id: sessionID)
        XCTAssertTrue(store.sessionSummaries().isEmpty)
        XCTAssertTrue(store.messages(sessionID: sessionID).isEmpty)
    }
}
