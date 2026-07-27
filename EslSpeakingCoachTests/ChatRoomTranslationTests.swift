import XCTest
@testable import EslSpeakingCoach

/// 翻訳の生成対象セッションの切り出しと文脈の組み立て（docs/plans/message-translation.md）。
@MainActor
final class ChatRoomTranslationTests: XCTestCase {
    private typealias Item = ChatRoomStore.TimelineItem

    private func divider(_ topic: String) -> Item {
        .sessionDivider(id: UUID(), text: "7/26 \(topic)", topic: topic)
    }

    private func ai(_ id: UUID, _ text: String, translation: String? = nil) -> Item {
        .aiMessage(ChatRoomStore.AIMessage(
            id: id, speaker: .chobi, text: text, translation: translation))
    }

    private func user(_ id: UUID, _ text: String, translation: String? = nil) -> Item {
        .userMessage(ChatRoomStore.UserMessage(id: id, text: text, translation: translation))
    }

    /// セッション中 / 終了直後: 対象は最後の区切り以降だけ（前のセッションは含めない）。
    func testTargetMessagesUseLastSessionOnly() {
        let oldID = UUID()
        let userID = UUID()
        let aiID = UUID()
        let timeline: [Item] = [
            divider("Old topic"),
            user(oldID, "I like ramen."),
            divider("Kyoto trip"),
            user(userID, "I went to Kyoto."),
            ai(aiID, "Oh, when?"),
        ]

        let targets = ChatRoomStore.translationTargetMessages(in: timeline)
        XCTAssertEqual(targets.map(\.id), [userID, aiID])
        XCTAssertEqual(targets.map(\.speaker), ["Learner", "Chobi"])
        XCTAssertEqual(ChatRoomStore.translationTargetTopic(in: timeline), "Kyoto trip")
    }

    /// トピックカード・フィードバックカード・システム通知は翻訳対象外（元から日本語）。
    func testTargetMessagesSkipCardsAndNotices() {
        let aiID = UUID()
        let timeline: [Item] = [
            divider("Kyoto trip"),
            ai(aiID, "Hi there!"),
            .systemNotice(id: UUID(), text: "エラー: 接続が切れました"),
            .topicCard(ChatRoomStore.TopicCard()),
            .feedbackCard(ChatRoomStore.FeedbackCard(
                sessionID: nil, topicTitle: "Kyoto trip", transcript: "")),
        ]
        XCTAssertEqual(ChatRoomStore.translationTargetMessages(in: timeline).map(\.id), [aiID])
    }

    /// セッションが 1 つも無いとき（履歴なしの起動直後）は対象もトピックも空。
    func testTargetMessagesWithoutAnySession() {
        let timeline: [Item] = [.topicCard(ChatRoomStore.TopicCard())]
        XCTAssertTrue(ChatRoomStore.translationTargetMessages(in: timeline).isEmpty)
        XCTAssertNil(ChatRoomStore.translationTargetTopic(in: timeline))
    }

    /// 未翻訳だけを 20 件チャンクの先頭から拾う（生成済みは飛ばす）。
    func testPendingMessagesSkipAlreadyTranslated() {
        let ids = (0..<25).map { _ in UUID() }
        var timeline: [Item] = [divider("Long session")]
        for (index, id) in ids.enumerated() {
            timeline.append(user(id, "line \(index)", translation: index < 3 ? "訳 \(index)" : nil))
        }

        let targets = ChatRoomStore.translationTargetMessages(in: timeline)
        let pending = targets.filter { $0.translation == nil }
        XCTAssertEqual(pending.count, 22)
        let chunk = Array(pending.prefix(ChatRoomStore.translationChunkSize))
        XCTAssertEqual(ChatRoomStore.translationChunkSize, 20)
        XCTAssertEqual(chunk.count, 20)
        XCTAssertEqual(chunk.first?.id, ids[3])
        XCTAssertEqual(chunk.last?.id, ids[22])
    }

    /// 文脈は直前 8 発話（同じセッション内）。
    func testContextLinesTakeEightPreceding() {
        let ids = (0..<12).map { _ in UUID() }
        var timeline: [Item] = [divider("Kyoto trip")]
        for (index, id) in ids.enumerated() {
            timeline.append(user(id, "line \(index)"))
        }
        let targets = ChatRoomStore.translationTargetMessages(in: timeline)

        let context = ChatRoomStore.contextLines(
            before: ids[10], in: targets, limit: TranslationClient.contextLineLimit)
        XCTAssertEqual(context.count, 8)
        XCTAssertEqual(context.first?.text, "line 2")
        XCTAssertEqual(context.last?.text, "line 9")
    }

    /// 8 件未満・セッション先頭（文脈なし）。
    func testContextLinesWhenFewerThanLimitOrAtSessionStart() {
        let ids = (0..<3).map { _ in UUID() }
        var timeline: [Item] = [divider("Kyoto trip")]
        for (index, id) in ids.enumerated() {
            timeline.append(user(id, "line \(index)"))
        }
        let targets = ChatRoomStore.translationTargetMessages(in: timeline)

        XCTAssertEqual(
            ChatRoomStore.contextLines(before: ids[2], in: targets, limit: 8).map(\.text),
            ["line 0", "line 1"])
        XCTAssertTrue(ChatRoomStore.contextLines(before: ids[0], in: targets, limit: 8).isEmpty)
        // 対象に含まれない ID（前セッションの発話など）も文脈なし
        XCTAssertTrue(ChatRoomStore.contextLines(before: UUID(), in: targets, limit: 8).isEmpty)
    }

    /// 訳の表示 ON / OFF は UserDefaults をまたいで復元される。
    func testTranslationVisibilityRoundTripsThroughUserDefaults() throws {
        let key = "chatRoomTranslationVisible"
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.removeObject(forKey: key)

        let container = try AppModelContainer.make(inMemory: true)
        let store = ChatRoomStore(container: container)
        // 既定は OFF（会話中の視界を汚さない）
        XCTAssertFalse(store.isTranslationVisible)

        store.setTranslationVisible(true)
        XCTAssertTrue(store.isTranslationVisible)
        XCTAssertTrue(ChatRoomStore(container: container).isTranslationVisible)

        store.setTranslationVisible(false)
        XCTAssertFalse(ChatRoomStore(container: container).isTranslationVisible)
    }
}
