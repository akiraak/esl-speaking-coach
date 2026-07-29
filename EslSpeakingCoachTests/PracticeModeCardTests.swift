import XCTest

@testable import EslSpeakingCoach

/// モード切替の副作用は「末尾の未使用カードを現モードのカードに差し替える」だけ
/// （docs/plans/word-practice-mode.md Phase 2）。
@MainActor
final class PracticeModeCardTests: XCTestCase {
    private func makeCard(
        mode: PracticeMode = .conversation, titles: [String] = [], isUsed: Bool = false
    ) -> ChatRoomStore.TopicCard {
        var card = ChatRoomStore.TopicCard(mode: mode)
        card.candidates = titles.map { TopicCandidate(title: $0, hook: "\($0)?", genre: "food") }
        card.isUsed = isUsed
        return card
    }

    /// 会話カードを捨てるときは候補を持ち越しへ戻す（会話モードに帰ってきたときに生きる）。
    func testReplacesTrailingConversationCardAndReturnsCandidates() {
        let timeline: [ChatRoomStore.TimelineItem] = [
            .systemNotice(id: UUID(), text: "前のセッション"),
            .topicCard(makeCard(titles: ["A", "B", "C"])),
        ]
        let replacement = ChatRoomStore.cardReplacement(in: timeline, newMode: .word)
        XCTAssertEqual(replacement.removedIndex, 1)
        XCTAssertEqual(replacement.carryOver?.map(\.title), ["A", "B", "C"])
    }

    /// 単語カードには候補が無いので、会話モードへ戻すときは持ち越しに触らない
    /// （単語モードへ切り替えたときに戻したぶんがそのまま生きる）。
    func testReplacingWordCardKeepsCarryOverUntouched() {
        let timeline: [ChatRoomStore.TimelineItem] = [.topicCard(makeCard(mode: .word))]
        let replacement = ChatRoomStore.cardReplacement(in: timeline, newMode: .conversation)
        XCTAssertEqual(replacement.removedIndex, 0)
        XCTAssertNil(replacement.carryOver)
    }

    /// 使用済みカード（過去の履歴）は差し替えない。
    func testDoesNotReplaceUsedCard() {
        let timeline: [ChatRoomStore.TimelineItem] = [
            .topicCard(makeCard(titles: ["A"], isUsed: true))
        ]
        let replacement = ChatRoomStore.cardReplacement(in: timeline, newMode: .word)
        XCTAssertNil(replacement.removedIndex)
        XCTAssertNil(replacement.carryOver)
    }

    /// 対象は末尾のカードだけ（それより前の未使用カードは実際には存在しないが、触らない）。
    func testLooksAtTrailingCardOnly() {
        let timeline: [ChatRoomStore.TimelineItem] = [
            .topicCard(makeCard(titles: ["A"])),
            .topicCard(makeCard(mode: .word, isUsed: true)),
        ]
        let replacement = ChatRoomStore.cardReplacement(in: timeline, newMode: .word)
        XCTAssertNil(replacement.removedIndex)
    }

    /// 同じモードのカードなら差し替えない（切替が無かった場合の保険）。
    func testDoesNotReplaceSameModeCard() {
        let timeline: [ChatRoomStore.TimelineItem] = [.topicCard(makeCard(titles: ["A"]))]
        XCTAssertNil(
            ChatRoomStore.cardReplacement(in: timeline, newMode: .conversation).removedIndex)
    }

    /// カードが 1 枚も無いタイムラインでは何もしない。
    func testNoCardInTimeline() {
        let timeline: [ChatRoomStore.TimelineItem] = [
            .systemNotice(id: UUID(), text: "起動直後")
        ]
        XCTAssertNil(ChatRoomStore.cardReplacement(in: timeline, newMode: .word).removedIndex)
    }

    /// セッション区切りは単語モードだけ「単語:」を前置する（履歴を遡ったときの見分け）。
    func testDividerLabelPerMode() {
        XCTAssertEqual(
            ChatRoomStore.dividerLabel(mode: .conversation, title: "好きなラーメン屋"),
            "好きなラーメン屋")
        XCTAssertEqual(
            ChatRoomStore.dividerLabel(mode: .word, title: "get around to"),
            "単語: get around to")
    }
}
