import XCTest

@testable import EslSpeakingCoach

/// 相槌フィルタ（docs/plans/always-on-voice-input.md Phase 3.5）。
/// 実機で実際にターンになってしまった文字列（2026-08-04 の Bluetooth セッション）を
/// そのまま固定しておく。
final class BackchannelFilterTests: XCTestCase {
    // MARK: - 落とすもの

    /// 実機で 1 ターンになってしまった相槌
    func testDropsBackchannelsSeenOnDevice() {
        XCTAssertTrue(BackchannelFilter.isBackchannel("Um,"))
        XCTAssertTrue(BackchannelFilter.isBackchannel("いいね。 そう"))
    }

    func testDropsCommonEnglishBackchannels() {
        for text in ["yeah", "Yeah!", "OK", "Okay.", "mm-hmm", "uh-huh", "I see", "right",
                     "wow", "Hmm...", "yeah yeah", "oh I see"] {
            XCTAssertTrue(BackchannelFilter.isBackchannel(text), "\(text) は相槌")
        }
    }

    func testDropsCommonJapaneseBackchannels() {
        for text in ["うん", "はい", "なるほど", "そうそう", "へえ", "たしかに",
                     "ありがとう", "ありがとうございます"] {
            XCTAssertTrue(BackchannelFilter.isBackchannel(text), "\(text) は相槌")
        }
    }

    /// キャッチボールにならない短い返事（語の組み合わせでしか判定できないもの）
    func testDropsShortRepliesThatDoNotAdvanceTheConversation() {
        for text in ["Thank you", "Thank you very much", "Thanks", "Thanks a lot",
                     "You too", "No problem"] {
            XCTAssertTrue(BackchannelFilter.isBackchannel(text), "\(text) は短い返事")
        }
    }

    /// 記号・大文字小文字に依らない（STT は終止記号をほとんど返さない）
    func testIgnoresPunctuationAndCase() {
        XCTAssertTrue(BackchannelFilter.isBackchannel("YEAH!!"))
        XCTAssertTrue(BackchannelFilter.isBackchannel("um"))
        XCTAssertTrue(BackchannelFilter.isBackchannel("Um."))
    }

    // MARK: - 落とさないもの

    /// 相槌で**始まる**だけの本文は落とさない（実機の「Yeah I do a similar chobi…」）
    func testKeepsUtteranceThatMerelyStartsWithBackchannel() {
        XCTAssertFalse(BackchannelFilter.isBackchannel(
            "Yeah I do a similar chobi so I usually read a book or work or"))
        XCTAssertFalse(BackchannelFilter.isBackchannel("I see the moon"))
        XCTAssertFalse(BackchannelFilter.isBackchannel("うん、それは面白い"))
    }

    /// 単発の間投詞も落とす（続きを言ってはじめて意味を持つ）。
    /// **Phase 4 の割り込み確定にこの判定を流用しないこと** — "Wait" は
    /// 読み上げを止めるべきだがターンにはしたくない語
    func testDropsBareInterjections() {
        for text in ["No", "Wait", "No, no, wait", "Stop", "Well", "Sorry", "ちょっと待って"] {
            XCTAssertTrue(BackchannelFilter.isBackchannel(text), "\(text) は単発の間投詞")
        }
    }

    /// 相手に振り返すだけの問い返しも落とす。ただし**全文一致**で持っているので、
    /// "you" を含む普通の文は落ちない（`words` に "you" を入れない理由）
    func testDropsBareTurnBackQuestions() {
        XCTAssertTrue(BackchannelFilter.isBackchannel("And you?"))
        XCTAssertTrue(BackchannelFilter.isBackchannel("You?"))
        XCTAssertTrue(BackchannelFilter.isBackchannel("How about you?"))
        XCTAssertFalse(BackchannelFilter.isBackchannel("Thank you for the tip"))
        XCTAssertFalse(BackchannelFilter.isBackchannel("And you? What do you do?"))
    }

    /// 間投詞に続きが付いていれば落とさない（意思表示そのものは失わない）
    func testKeepsInterjectionFollowedByContent() {
        XCTAssertFalse(BackchannelFilter.isBackchannel("No I don't think so"))
        XCTAssertFalse(BackchannelFilter.isBackchannel("Wait I mean the airport"))
    }

    /// 猶予中に言い足したぶんと合流したターン全文で判定するので、1 語足せば通る
    /// （`TurnBasedVoiceSession` はこの判定をターン全文に対して 1 度だけ掛ける）
    func testKeepsBackchannelFollowedByContent() {
        XCTAssertFalse(BackchannelFilter.isBackchannel("Yes I love it"))
        XCTAssertFalse(BackchannelFilter.isBackchannel("Thank you Chobi that helps"))
    }

    /// 空文字は相槌にしない（空セグメントの既存処理に任せる）
    func testEmptyIsNotBackchannel() {
        XCTAssertFalse(BackchannelFilter.isBackchannel(""))
        XCTAssertFalse(BackchannelFilter.isBackchannel("   "))
        XCTAssertFalse(BackchannelFilter.isBackchannel("..."))
    }

    // MARK: - 送る価値があるか（語彙 + 語数）

    /// 相槌リストに無い語でも、**語数が足りなければ送らない**（実機で「Hello」が通ってしまった）。
    /// 既定は 3 語（管理画面「音声入力」で変えられる）
    func testDoesNotSendUtterancesShorterThanMinimum() {
        XCTAssertEqual(BackchannelFilter.defaultMinimumTurnWordCount, 3)
        for text in ["Hello", "Hi", "Coffee", "Tokyo.", "Hello Chobi", "I agree"] {
            XCTAssertFalse(BackchannelFilter.isWorthSending(text), "\(text) は 3 語未満なので送らない")
            // 相槌リストには入っていない（落ちる理由は語数であることを固定する）
            XCTAssertFalse(BackchannelFilter.isBackchannel(text))
        }
    }

    /// 既定の語数を満たせば送る（相槌で始まっていても中身が続けば送る）
    func testSendsUtterancesThatMeetTheMinimum() {
        for text in ["Yes I love it", "It was fun", "I like coffee"] {
            XCTAssertTrue(BackchannelFilter.isWorthSending(text), "\(text) は送る")
        }
    }

    /// 最小語数は呼び出し側から差し替えられる（管理画面の設定がここへ入る）
    func testMinimumWordCountIsConfigurable() {
        XCTAssertTrue(BackchannelFilter.isWorthSending("Hello Chobi", minimumWordCount: 2))
        XCTAssertTrue(BackchannelFilter.isWorthSending("Hello", minimumWordCount: 1))
        XCTAssertFalse(BackchannelFilter.isWorthSending("I like coffee", minimumWordCount: 4))
        // 1 語まで下げても相槌の語彙判定は効いたまま
        XCTAssertFalse(BackchannelFilter.isWorthSending("Yes", minimumWordCount: 1))
    }

    /// 語数を満たしていても相槌だけなら送らない
    func testDoesNotSendMultiWordBackchannels() {
        for text in ["yeah yeah", "Thank you", "I see", "うん うん"] {
            XCTAssertFalse(BackchannelFilter.isWorthSending(text), "\(text) は相槌なので送らない")
        }
    }

    // MARK: - 割り込み確定（Phase 4: 文章を話し始めたか）

    /// 相槌・間投詞の単発では Chobi を止めない
    func testDoesNotStartSentenceForBackchannels() {
        for text in ["Um", "Wait", "No", "Yeah", "Thank you", "and", "so", "うん", "なるほど"] {
            XCTAssertFalse(BackchannelFilter.startsSentence(text), "\(text) では止めない")
        }
    }

    /// 中身のある語が 1 つ出た時点で止める
    func testStartsSentenceOnFirstContentWord() {
        for text in ["Actually", "I", "I think", "No I don't", "Wait I mean", "and I",
                     "yeah but the station"] {
            XCTAssertTrue(BackchannelFilter.startsSentence(text), "\(text) では止める")
        }
    }

    /// **"I" だけが 2 つの判定で扱いが違う。**
    /// ターンにはしない（単発の "I" は言い直しの途中）が、読み上げは止める
    /// （文頭に立つ語なので、2 語目を待つと実測で中央値 2.1 秒かかる）
    func testPronounIIsContentOnlyForBargeIn() {
        XCTAssertTrue(BackchannelFilter.isBackchannel("I"))
        XCTAssertTrue(BackchannelFilter.startsSentence("I"))
    }

    func testEmptyDoesNotStartSentence() {
        XCTAssertFalse(BackchannelFilter.startsSentence(""))
        XCTAssertFalse(BackchannelFilter.startsSentence("..."))
    }

    // MARK: - 正規化

    func testNormalizationSplitsOnPunctuationAndHyphen() {
        XCTAssertEqual(BackchannelFilter.normalizedTokens("Uh-huh, I see."), ["uh", "huh", "i", "see"])
        XCTAssertEqual(BackchannelFilter.normalizedTokens("いいね。 そう"), ["いいね", "そう"])
    }
}
