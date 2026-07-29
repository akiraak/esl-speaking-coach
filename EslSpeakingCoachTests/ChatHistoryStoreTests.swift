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

    /// 翻訳: 保存 → 再取得、未生成のとき nil、セッション削除で cascade。
    func testTranslationRoundTrip() throws {
        let store = try makeStore()
        let sessionID = UUID()
        let userID = UUID()
        let chobiID = UUID()
        store.beginSession(id: sessionID, topicTitle: "Kyoto trip")
        store.appendMessage(id: userID, speaker: .user, text: "I went to Kyoto.")
        store.appendMessage(id: chobiID, speaker: .chobi, text: "Oh, when?")
        store.updateTranslation(id: userID, text: "京都に行ったよ。")
        store.endActiveSession()

        var messages = store.messages(sessionID: sessionID)
        XCTAssertEqual(messages[0].translation, "京都に行ったよ。")
        XCTAssertNil(messages[1].translation)

        // 終了後（アクティブ外）の発話にも後から訳を保存できる
        store.updateTranslation(id: chobiID, text: "え、いつ行ったの？")
        messages = store.messages(sessionID: sessionID)
        XCTAssertEqual(messages[1].translation, "え、いつ行ったの？")

        store.deleteSession(id: sessionID)
        XCTAssertTrue(store.messages(sessionID: sessionID).isEmpty)
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

    /// 調査用ログ: 記録順に取り出せて、セッション削除で一緒に消える。
    func testLogRoundTripAndCascadeDelete() throws {
        let store = try makeStore()
        let sessionID = UUID()
        store.beginSession(id: sessionID, topicTitle: "Latency check")
        store.appendMessage(id: UUID(), speaker: .user, text: "Hello")
        store.appendLog(kind: .notice, text: "STT へ接続中…")
        store.appendLog(kind: .metrics, text: "体感 1200ms | 無音待ち 800")
        store.appendLog(kind: .error, text: "接続が切れました")
        store.endActiveSession()

        let logs = store.logs(sessionID: sessionID)
        XCTAssertEqual(logs.map(\.kind), [.notice, .metrics, .error])
        XCTAssertEqual(logs[1].text, "体感 1200ms | 無音待ち 800")

        store.deleteSession(id: sessionID)
        XCTAssertTrue(store.logs(sessionID: sessionID).isEmpty)
    }

    /// セッション外のログは記録しない（会話ログの一部としてのみ残す）。
    func testLogOutsideSessionIsIgnored() throws {
        let store = try makeStore()
        store.appendLog(kind: .notice, text: "セッション前の通知")

        let sessionID = UUID()
        store.beginSession(id: sessionID, topicTitle: "Later")
        XCTAssertTrue(store.logs(sessionID: sessionID).isEmpty)
    }

    /// エラー再開でセッションを resume したあとも、ログは既存の続きから追記される。
    func testResumeSessionContinuesLogOrder() throws {
        let store = try makeStore()
        let sessionID = UUID()
        store.beginSession(id: sessionID, topicTitle: "Resumed")
        store.appendLog(kind: .notice, text: "1 番目")
        // 別セッションを挟んでから元のセッションへ戻る
        store.beginSession(id: UUID(), topicTitle: "Other")
        store.resumeSession(id: sessionID)
        store.appendLog(kind: .notice, text: "2 番目")

        XCTAssertEqual(store.logs(sessionID: sessionID).map(\.text), ["1 番目", "2 番目"])
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

    /// ジャンルはトピックカードから選んだときだけ付く。自作トピックは nil で除外対象にしない。
    func testRecentTopicGenresSkipsSessionsWithoutGenre() throws {
        let store = try makeStore()
        for (title, genre) in [("Food", "food"), ("Custom", nil), ("Trip", "travel")] {
            store.beginSession(id: UUID(), topicTitle: title, topicGenre: genre)
            store.appendMessage(id: UUID(), speaker: .user, text: "hi")
            store.endActiveSession()
        }
        XCTAssertEqual(store.recentTopicGenres(limit: 8), ["food", "travel"])
        XCTAssertEqual(store.recentTopicGenres(limit: 1), ["travel"])
        XCTAssertEqual(store.recentSessions(limit: 10).map(\.topicGenre), ["food", nil, "travel"])
    }

    /// 発話ゼロで終了したセッションは残さない。
    func testEmptySessionIsDiscardedOnEnd() throws {
        let store = try makeStore()
        store.beginSession(id: UUID(), topicTitle: "No talk")
        store.endActiveSession()
        XCTAssertTrue(store.recentSessions(limit: 10).isEmpty)
    }

    /// 練習モードはセッションに記録され、単語モードのぶんだけ recentWords で引ける。
    /// トピック重複回避のタイトルには練習語を混ぜない。
    func testPracticeModeIsRecordedAndWordsAreListedSeparately() throws {
        let store = try makeStore()
        for (title, mode) in [
            ("Morning routines", PracticeMode.conversation),
            ("get around to", .word),
            ("Weekend plans", .conversation),
            ("look forward to", .word),
        ] {
            store.beginSession(id: UUID(), topicTitle: title, mode: mode)
            store.appendMessage(id: UUID(), speaker: .user, text: "hi")
            store.endActiveSession()
        }

        XCTAssertEqual(
            store.recentSessions(limit: 10).map(\.mode),
            [.conversation, .word, .conversation, .word])
        // 単語カードのピルにそのまま並べるので新しい順で返す
        XCTAssertEqual(store.recentWords(limit: 10), ["look forward to", "get around to"])
        XCTAssertEqual(store.recentWords(limit: 1), ["look forward to"])
        XCTAssertEqual(
            store.recentTopicTitles(limit: 10), ["Morning routines", "Weekend plans"])
        // 管理画面の一覧（新しい順）でもモードが分かる
        XCTAssertEqual(
            store.sessionSummaries().map(\.mode), [.word, .conversation, .word, .conversation])
    }

    /// モード導入前に保存されたセッション（modeRawValue が nil）は会話モードとして扱う。
    func testSessionWithoutModeIsTreatedAsConversation() throws {
        let store = try makeStore()
        store.beginSession(id: UUID(), topicTitle: "Legacy")
        store.appendMessage(id: UUID(), speaker: .user, text: "hi")
        store.endActiveSession()

        // 既存ストアの行を模して列を空にする
        let session = try XCTUnwrap(store.recentSessions(limit: 1).first)
        session.modeRawValue = nil

        XCTAssertEqual(session.mode, .conversation)
        XCTAssertEqual(store.recentTopicTitles(limit: 10), ["Legacy"])
        XCTAssertTrue(store.recentWords(limit: 10).isEmpty)
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
