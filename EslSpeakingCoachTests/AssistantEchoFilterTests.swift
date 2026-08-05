import XCTest

@testable import EslSpeakingCoach

/// AI 発話のエコー判定（docs/plans/always-on-voice-input.md Phase 5）。
/// **取りこぼし（エコーを通す）より誤検知（学習者の発話を捨てる）の方が害が大きい**ので、
/// 正当な発話が通ることを厚めに固定する。
final class AssistantEchoFilterTests: XCTestCase {
    /// Chobi の読み上げ 1 ターンぶん（この後の判定はすべてこれを参照する）
    private let spoken = "So what do you usually do before bed? I like reading a book."

    // MARK: - エコーとみなす

    /// そのまま拾われた（語順まで一致する）
    func testDetectsVerbatimEcho() {
        XCTAssertTrue(AssistantEchoFilter.isEcho(
            transcript: "what do you usually do before bed", spokenText: spoken))
    }

    /// STT が一部を取り違えても、外れた語まで AI の語（＝ 被覆率が高い）ならエコー
    func testDetectsGarbledEchoByCoverage() {
        XCTAssertTrue(AssistantEchoFilter.isEcho(
            transcript: "so what do you usually to before bad", spokenText: spoken))
    }

    /// 短い発話でも、全体の 75% 以上が連続一致していればエコー
    func testDetectsShortEchoByRatio() {
        XCTAssertTrue(AssistantEchoFilter.isEcho(
            transcript: "I like reading", spokenText: spoken))
    }

    /// 記号・大文字小文字は無視する
    func testIgnoresPunctuationAndCase() {
        XCTAssertTrue(AssistantEchoFilter.isEcho(
            transcript: "WHAT DO YOU USUALLY DO!!", spokenText: spoken))
    }

    // MARK: - 通す（誤検知させない）

    /// **AI の言い回しを借りた正当な発話は通す。** 英会話練習ではこれが普通。
    /// 2 つ目は AI の 5 語（"I like reading a book"）をそのまま含むが、
    /// 残りが自分の言葉なので被覆率で通る — ここが連続一致だけでは足りない理由
    func testKeepsLearnerReusingAssistantWords() {
        XCTAssertFalse(AssistantEchoFilter.isEcho(
            transcript: "I usually read a book before bed with my son",
            spokenText: spoken))
        XCTAssertFalse(AssistantEchoFilter.isEcho(
            transcript: "yes I like reading a book too but not every night",
            spokenText: spoken))
    }

    /// 単語は重なるが語順が違う（＝ 反射ではなく自分の文）
    func testKeepsSameWordsInDifferentOrder() {
        XCTAssertFalse(AssistantEchoFilter.isEcho(
            transcript: "before bed I do reading usually", spokenText: spoken))
    }

    /// 無関係な発話
    func testKeepsUnrelatedSpeech() {
        XCTAssertFalse(AssistantEchoFilter.isEcho(
            transcript: "I went to the airport yesterday", spokenText: spoken))
    }

    /// 参照が空（まだ 1 文字も読み上げていない）なら判定しない
    func testKeepsEverythingWhenNothingWasSpoken() {
        XCTAssertFalse(AssistantEchoFilter.isEcho(
            transcript: "what do you usually do before bed", spokenText: ""))
        XCTAssertFalse(AssistantEchoFilter.isEcho(transcript: "", spokenText: spoken))
    }

    /// 2 語の一致では落とさない（最低 3 語 + 割合）
    func testKeepsTwoWordOverlap() {
        XCTAssertFalse(AssistantEchoFilter.isEcho(transcript: "a book", spokenText: spoken))
    }

    // MARK: - 連続一致の長さ

    func testLongestCommonRun() {
        XCTAssertEqual(
            AssistantEchoFilter.longestCommonRun(["a", "b", "c", "d"], ["x", "b", "c", "y"]), 2)
        XCTAssertEqual(
            AssistantEchoFilter.longestCommonRun(["a", "b"], ["c", "d"]), 0)
        XCTAssertEqual(AssistantEchoFilter.longestCommonRun([], ["a"]), 0)
    }
}
