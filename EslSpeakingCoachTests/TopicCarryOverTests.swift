import XCTest

@testable import EslSpeakingCoach

/// 次のトピックカードは「やった 1 件を落として残りを持ち越し + 補充 1 件」で作る
/// （docs/plans/topic-card-carry-over.md）。
@MainActor
final class TopicCarryOverTests: XCTestCase {
    private func makeCard(_ titles: [String]) -> ChatRoomStore.TopicCard {
        var card = ChatRoomStore.TopicCard()
        card.candidates = titles.map { TopicCandidate(title: $0, hook: "\($0)?", genre: "food") }
        return card
    }

    // MARK: - 持ち越しの切り出し

    /// 選んだ 1 件だけ落ちて、残り 2 件が持ち越される。
    func testDropsSelectedCandidateAndKeepsRest() {
        let carried = ChatRoomStore.carryOverCandidates(
            from: makeCard(["A", "B", "C"]), selectedTitle: "B")
        XCTAssertEqual(carried.map(\.title), ["A", "C"])
    }

    /// 自作トピック・固定候補「話しかける」では候補が消費されないので、先頭 2 件だけ持ち越す
    /// （常に「持ち越し + 生成 1 件」の形にするため）。
    func testKeepsAtMostTwoWhenNothingWasConsumed() {
        let carried = ChatRoomStore.carryOverCandidates(
            from: makeCard(["A", "B", "C"]),
            selectedTitle: ChatRoomStore.talkFirstCandidate.title)
        XCTAssertEqual(carried.map(\.title), ["A", "B"])
    }

    /// カードが無い（起動直後・DEBUG の自動開始）なら持ち越し無し = 3 件生成に戻る。
    func testNoCarryOverWithoutCard() {
        XCTAssertTrue(
            ChatRoomStore.carryOverCandidates(from: nil, selectedTitle: "A").isEmpty)
    }

    /// 候補が 1 件しか無いカードから選んだら持ち越しは無い。
    func testNoCarryOverWhenOnlyCandidateWasSelected() {
        let carried = ChatRoomStore.carryOverCandidates(
            from: makeCard(["A"]), selectedTitle: "A")
        XCTAssertTrue(carried.isEmpty)
    }

    // MARK: - 固定候補「話しかける」

    /// 固定候補を選んだセッションだけ、最初のターンを学習者から始める
    /// （docs/plans/learner-first-topic.md）。
    func testLearnerFirstOnlyForTalkFirstCandidate() {
        XCTAssertTrue(
            ChatRoomStore.isLearnerFirstTopic(ChatRoomStore.talkFirstCandidate.title))
        XCTAssertFalse(ChatRoomStore.isLearnerFirstTopic("週末の予定"))
        XCTAssertFalse(ChatRoomStore.isLearnerFirstTopic(""))
    }

    // MARK: - 生成ぶんとのマージ

    /// 持ち越しが先、生成ぶんが後ろ。
    func testAppendsGeneratedAfterCarryOver() {
        let merged = ChatRoomStore.mergedCandidates(
            carryOver: makeCard(["A", "C"]).candidates,
            generated: [TopicCandidate(title: "D", hook: "D?")])
        XCTAssertEqual(merged.map(\.title), ["A", "C", "D"])
    }

    /// 生成が持ち越しと同じタイトルを返しても二重に並べない。
    func testDropsGeneratedDuplicateTitle() {
        let merged = ChatRoomStore.mergedCandidates(
            carryOver: makeCard(["A", "C"]).candidates,
            generated: [
                TopicCandidate(title: "C", hook: "C?"),
                TopicCandidate(title: "D", hook: "D?"),
            ])
        XCTAssertEqual(merged.map(\.title), ["A", "C", "D"])
    }

    /// 上限 3 件を超えない（🔄 で 3 件返ってきたケース）。
    func testCapsAtCandidateCount() {
        let merged = ChatRoomStore.mergedCandidates(
            carryOver: [],
            generated: makeCard(["A", "B", "C", "D"]).candidates)
        XCTAssertEqual(merged.count, ChatRoomStore.topicCandidateCount)
        XCTAssertEqual(merged.map(\.title), ["A", "B", "C"])
    }

    /// 生成が空（失敗）でも持ち越しは残る = カードが空にならない。
    func testKeepsCarryOverWhenGenerationReturnsNothing() {
        let merged = ChatRoomStore.mergedCandidates(
            carryOver: makeCard(["A", "C"]).candidates, generated: [])
        XCTAssertEqual(merged.map(\.title), ["A", "C"])
    }
}
