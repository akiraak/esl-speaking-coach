import XCTest

@testable import EslSpeakingCoach

/// 発話終端からターンを送るまでの猶予の出し分け（docs/plans/always-on-voice-input.md Phase 1）。
/// 「言い淀んだ末尾は長く待つ / 完結文は待たない」が境界で崩れないことを固定する。
final class TurnCommitGraceTests: XCTestCase {
    private let grace = TurnCommitGrace(standard: 1.0)

    // MARK: - 続きそうな終わり方

    /// 接続詞・前置詞・冠詞・be 動詞・助動詞・フィラーで切れたら長い猶予
    func testEndingWithFunctionWordWaitsLonger() {
        for text in [
            "I went to the",
            "yesterday I was",
            "we can",
            "it happened because",
            "I think that my",
            "so I um",
            "I have to go and",
        ] {
            let decision = grace.decide(for: text)
            XCTAssertEqual(decision.kind, .continuing, text)
            XCTAssertEqual(decision.duration, 1.6, accuracy: 0.0001, text)
        }
    }

    /// 大文字・末尾の空白でも同じ判定になる
    func testContinuingWordIsCaseAndSpaceInsensitive() {
        XCTAssertEqual(grace.decide(for: "I went to THE  ").kind, .continuing)
    }

    /// 読点・ダッシュ・3 点リーダは「まだ続く」印（3 点リーダを完結扱いにしない）
    func testTrailingMarksAreTreatedAsContinuing() {
        XCTAssertEqual(grace.decide(for: "I went to the station,").kind, .continuing)
        XCTAssertEqual(grace.decide(for: "I mean—").kind, .continuing)
        XCTAssertEqual(grace.decide(for: "I went to the station...").kind, .continuing)
    }

    // MARK: - 完結した終わり方

    /// 句点・疑問符・感嘆符で終わったら短い猶予（現行に近い応答速度を保つ）
    func testCompletedSentenceWaitsShorter() {
        for text in ["I went to the station.", "How about you?", "That's great!"] {
            let decision = grace.decide(for: text)
            XCTAssertEqual(decision.kind, .completed, text)
            XCTAssertEqual(decision.duration, 0.4, accuracy: 0.0001, text)
        }
    }

    /// 句読点の直前が機能語でも、完結の印が優先される
    func testTerminatorWinsOverLastWord() {
        XCTAssertEqual(grace.decide(for: "I don't know what to do with the.").kind, .completed)
    }

    // MARK: - どちらとも言えない

    /// 内容語で終わっていて句読点も無ければ標準
    func testPlainEndingUsesStandard() {
        for text in ["I went to the station", "sounds good", "coffee"] {
            let decision = grace.decide(for: text)
            XCTAssertEqual(decision.kind, .standard, text)
            XCTAssertEqual(decision.duration, 1.0, accuracy: 0.0001, text)
            XCTAssertEqual(decision.trigger, "", text)
        }
    }

    /// 文末にも普通に立つ語は続き扱いにしない（完結した発話まで待たされないための線引き）
    func testSentenceFinalWordsAreNotContinuing() {
        for text in ["thank you", "I like it", "over there", "I did some", "yes"] {
            XCTAssertEqual(grace.decide(for: text).kind, .standard, text)
        }
    }

    /// 空文字・空白のみは判断材料が無いので標準（呼び出し側では猶予を挟まないケース）
    func testEmptyTextUsesStandard() {
        XCTAssertEqual(grace.decide(for: "").kind, .standard)
        XCTAssertEqual(grace.decide(for: "   ").kind, .standard)
    }

    // MARK: - 設定

    /// 長短は標準値からの固定比。標準を動かせば 3 つとも比例して動く
    func testDurationsScaleWithStandard() {
        let slow = TurnCommitGrace(standard: 2.0)
        XCTAssertEqual(slow.decide(for: "I went to the").duration, 3.2, accuracy: 0.0001)
        XCTAssertEqual(slow.decide(for: "sounds good").duration, 2.0, accuracy: 0.0001)
        XCTAssertEqual(slow.decide(for: "sounds good.").duration, 0.8, accuracy: 0.0001)
    }

    /// standard = 0 は猶予なし（従来どおり確定した瞬間に送る）
    func testZeroStandardDisablesGrace() {
        let off = TurnCommitGrace(standard: 0)
        XCTAssertEqual(off.decide(for: "I went to the").duration, 0)
        XCTAssertEqual(off.decide(for: "sounds good").duration, 0)
    }

    /// 会話ログの 1 行（実機で理由を追えることが Phase 1 の確認項目）
    func testLogDescriptionIncludesReason() {
        XCTAssertEqual(grace.decide(for: "I went to the").logDescription, "1.60 秒（続きそう: \"the\"）")
        XCTAssertEqual(grace.decide(for: "sounds good.").logDescription, "0.40 秒（完結: \".\"）")
        XCTAssertEqual(grace.decide(for: "sounds good").logDescription, "1.00 秒（標準）")
    }

    /// 末尾語の取り出し（記号は落とし、アポストロフィは語の一部として残す）
    func testLastWordExtraction() {
        XCTAssertEqual(TurnCommitGrace.lastWord(of: "I went to the station"), "station")
        XCTAssertEqual(TurnCommitGrace.lastWord(of: "I don't"), "don't")
        XCTAssertEqual(TurnCommitGrace.lastWord(of: "well, um"), "um")
        XCTAssertEqual(TurnCommitGrace.lastWord(of: ""), "")
    }
}
