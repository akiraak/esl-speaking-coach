import XCTest
@testable import EslSpeakingCoach

final class SentenceChunkerTests: XCTestCase {
    func testEmitsSentenceOnlyAfterTrailingWhitespace() {
        var chunker = SentenceChunker()
        XCTAssertEqual(chunker.consume("Hello! How are you?"), ["Hello!"])
        // 末尾の "you?" は後続が来る可能性があるため flush まで保持される
        XCTAssertEqual(chunker.flush(), "How are you?")
    }

    func testSentenceSplitAcrossDeltas() {
        var chunker = SentenceChunker()
        XCTAssertEqual(chunker.consume("Hi the"), [])
        XCTAssertEqual(chunker.consume("re! Nice to"), ["Hi there!"])
        XCTAssertEqual(chunker.consume(" meet you. "), ["Nice to meet you."])
        XCTAssertNil(chunker.flush())
    }

    func testDecimalNumberIsNotSplit() {
        var chunker = SentenceChunker()
        let sentences = chunker.consume("It costs 3.5 dollars today. Right")
        XCTAssertEqual(sentences, ["It costs 3.5 dollars today."])
        XCTAssertEqual(chunker.flush(), "Right")
    }

    func testNewlineIsBoundary() {
        var chunker = SentenceChunker()
        XCTAssertEqual(chunker.consume("First line\nSecond"), ["First line"])
        XCTAssertEqual(chunker.flush(), "Second")
    }

    func testClosingQuoteStaysWithSentence() {
        var chunker = SentenceChunker()
        XCTAssertEqual(chunker.consume("He said \"stop.\" Then he left. "),
                       ["He said \"stop.\"", "Then he left."])
    }

    func testPunctuationOnlyFragmentIsDropped() {
        var chunker = SentenceChunker()
        XCTAssertEqual(chunker.consume("... \nOkay. "), ["Okay."])
        XCTAssertNil(chunker.flush())
    }

    func testFlushReturnsNilWhenEmpty() {
        var chunker = SentenceChunker()
        XCTAssertNil(chunker.flush())
    }
}
