import XCTest
@testable import EslSpeakingCoach

final class ScriptStreamChunkerTests: XCTestCase {
    func testTwoUtterancesWithTagsAndSentenceSplit() {
        var chunker = ScriptStreamChunker()
        var sentences = chunker.consume("Chobi: Hello! How was your day?\nNaruko: Nice to see you.\n")
        sentences += chunker.flush()

        XCTAssertEqual(sentences, [
            ScriptSentence(utteranceIndex: 0, speaker: .chobi, text: "Hello!"),
            ScriptSentence(utteranceIndex: 0, speaker: .chobi, text: "How was your day?"),
            ScriptSentence(utteranceIndex: 1, speaker: .naruko, text: "Nice to see you."),
        ])
        XCTAssertFalse(chunker.endDetected)
    }

    /// タグがデルタ境界で割れても行バッファで吸収する（conversation-design.md）。
    func testTagSplitAcrossDeltas() {
        var chunker = ScriptStreamChunker()
        XCTAssertEqual(chunker.consume("Naru"), [])
        XCTAssertEqual(
            chunker.consume("ko: Ramen again? "),
            [ScriptSentence(utteranceIndex: 0, speaker: .naruko, text: "Ramen again?")])
        XCTAssertEqual(chunker.flush(), [])
    }

    /// タグの無い行は直前の speaker（ターン先頭なら Chobi）に帰属させる。
    func testUntaggedLineFallsBackToPreviousSpeaker() {
        var chunker = ScriptStreamChunker()
        var sentences = chunker.consume("Good morning everyone.\nNaruko: Hi!\nAnd what did you eat?\n")
        sentences += chunker.flush()

        XCTAssertEqual(sentences, [
            ScriptSentence(utteranceIndex: 0, speaker: .chobi, text: "Good morning everyone."),
            ScriptSentence(utteranceIndex: 1, speaker: .naruko, text: "Hi!"),
            ScriptSentence(utteranceIndex: 2, speaker: .naruko, text: "And what did you eat?"),
        ])
    }

    /// 単独行の [end] は表示・読み上げ対象にせず endDetected を立てる。
    func testEndMarkerOnOwnLine() {
        var chunker = ScriptStreamChunker()
        var sentences = chunker.consume("Chobi: Bye bye, take care!\n[end]")
        sentences += chunker.flush()

        XCTAssertEqual(sentences, [
            ScriptSentence(utteranceIndex: 0, speaker: .chobi, text: "Bye bye, take care!"),
        ])
        XCTAssertTrue(chunker.endDetected)
    }

    /// 仕様外だが行内に [end] が混ざっても除去して検知する。
    func testEndMarkerInlineIsStripped() {
        var chunker = ScriptStreamChunker()
        var sentences = chunker.consume("Chobi: See you soon. [end]")
        sentences += chunker.flush()

        XCTAssertEqual(sentences, [
            ScriptSentence(utteranceIndex: 0, speaker: .chobi, text: "See you soon."),
        ])
        XCTAssertTrue(chunker.endDetected)
    }

    /// 同一発話内の複数文は utteranceIndex を共有し、文単位で TTS へ流せる。
    func testSentencesWithinUtteranceShareIndexAcrossDeltas() {
        var chunker = ScriptStreamChunker()
        var sentences = chunker.consume("Chobi: I love coffee. Especial")
        sentences += chunker.consume("ly in the morning. What about you?")
        sentences += chunker.flush()

        XCTAssertEqual(sentences, [
            ScriptSentence(utteranceIndex: 0, speaker: .chobi, text: "I love coffee."),
            ScriptSentence(utteranceIndex: 0, speaker: .chobi, text: "Especially in the morning."),
            ScriptSentence(utteranceIndex: 0, speaker: .chobi, text: "What about you?"),
        ])
    }

    /// 空行は発話として index を消費しない。
    func testEmptyLinesDoNotConsumeUtteranceIndex() {
        var chunker = ScriptStreamChunker()
        var sentences = chunker.consume("Chobi: Hi there.\n\nNaruko: Hello!\n")
        sentences += chunker.flush()

        XCTAssertEqual(sentences, [
            ScriptSentence(utteranceIndex: 0, speaker: .chobi, text: "Hi there."),
            ScriptSentence(utteranceIndex: 1, speaker: .naruko, text: "Hello!"),
        ])
    }

    func testFlushResolvesPendingTagPrefix() {
        var chunker = ScriptStreamChunker()
        // "Chobi" まで届いた時点でストリームが終わった → タグ未完成なので本文扱い
        XCTAssertEqual(chunker.consume("Chobi"), [])
        XCTAssertEqual(
            chunker.flush(),
            [ScriptSentence(utteranceIndex: 0, speaker: .chobi, text: "Chobi")])
    }
}
