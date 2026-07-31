import XCTest

@testable import EslSpeakingCoach

/// モード切替の副作用は「末尾の未使用カードを現モードのカードに差し替える」だけ
/// （docs/specs/word-practice.md）。
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

    /// クイズカードも候補を持たないので単語カードと同じ扱い（docs/plans/word-quiz-mode.md）。
    /// 会話 → クイズは候補を持ち越しへ戻し、クイズ → 会話は持ち越しに触らない。
    func testQuizCardReplacementBehavesLikeWordCard() {
        let toQuiz = ChatRoomStore.cardReplacement(
            in: [.topicCard(makeCard(titles: ["A", "B", "C"]))], newMode: .quiz)
        XCTAssertEqual(toQuiz.removedIndex, 0)
        XCTAssertEqual(toQuiz.carryOver?.map(\.title), ["A", "B", "C"])

        let fromQuiz = ChatRoomStore.cardReplacement(
            in: [.topicCard(makeCard(mode: .quiz))], newMode: .conversation)
        XCTAssertEqual(fromQuiz.removedIndex, 0)
        XCTAssertNil(fromQuiz.carryOver)
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

    /// セッション区切りは単語モードだけ「単語:」を前置する。クイズは**出題語を出さない**
    /// 固定文言（区切りはクイズ開始と同時に出るので、語を出すと答えが見える）。
    func testDividerLabelPerMode() {
        XCTAssertEqual(
            ChatRoomStore.dividerLabel(mode: .conversation, title: "好きなラーメン屋"),
            "好きなラーメン屋")
        XCTAssertEqual(
            ChatRoomStore.dividerLabel(mode: .word, title: "get around to"),
            "単語: get around to")
        XCTAssertEqual(
            ChatRoomStore.dividerLabel(mode: .quiz, title: "put off, resilient"),
            "クイズ")
    }
}
