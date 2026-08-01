import XCTest
@testable import EslSpeakingCoach

/// 登録シートのストア（チップ分割・選択結合・文脈切り出し・正規化提案・登録）のテスト
/// （docs/plans/tap-word-registration.md Phase 2）。
@MainActor
final class WordRegisterStoreTests: XCTestCase {
    // MARK: - tokens(from:)

    func testTokensStripSurroundingPunctuation() {
        XCTAssertEqual(
            WordRegisterStore.tokens(from: "\u{201C}Hello,\u{201D} she said: don't stop!"),
            ["Hello", "she", "said", "don't", "stop"])
    }

    func testTokensKeepInnerHyphenAndDropNonWords() {
        // 英字を含まないトークン（数値・ダッシュ）は落とし、語中のハイフンは残す
        XCTAssertEqual(
            WordRegisterStore.tokens(from: "The co-op. costs 3.5 — right?"),
            ["The", "co-op", "costs", "right"])
    }

    func testTokensEmptyText() {
        XCTAssertEqual(WordRegisterStore.tokens(from: "  \n "), [])
    }

    // MARK: - phrase(selectedIndices:tokens:)

    func testPhraseJoinsInAppearanceOrder() {
        let tokens = ["I", "picked", "it", "up", "yesterday"]
        // 選択順ではなく出現順（インデックス順）で結合する
        XCTAssertEqual(
            WordRegisterStore.phrase(selectedIndices: [3, 1], tokens: tokens),
            "picked up")
    }

    func testPhraseIgnoresOutOfRangeIndices() {
        XCTAssertEqual(
            WordRegisterStore.phrase(selectedIndices: [0, 9], tokens: ["run"]),
            "run")
    }

    // MARK: - contextWindow

    func testContextWindowReturnsShortTextAsIs() {
        let text = "I picked it up yesterday."
        XCTAssertEqual(
            WordRegisterStore.contextWindow(in: text, around: "picked", maxLength: 240),
            text)
    }

    func testContextWindowCentersOnWordInLongText() {
        let text = String(repeating: "a", count: 200) + " target word here " + String(repeating: "b", count: 200)
        let window = WordRegisterStore.contextWindow(in: text, around: "target", maxLength: 100)
        XCTAssertEqual(window.count, 100)
        XCTAssertTrue(window.contains("target"))
    }

    func testContextWindowFallsBackToPrefixWhenWordMissing() {
        let text = String(repeating: "x", count: 300)
        let window = WordRegisterStore.contextWindow(in: text, around: "none", maxLength: 100)
        XCTAssertEqual(window, String(repeating: "x", count: 100))
    }

    // MARK: - 選択と正規化提案

    /// テスト用ストア（デバウンス 0・スタブクライアント）。
    private func makeStore(
        messageText: String,
        normalize: @escaping WordRegisterStore.NormalizeClient = { word, _ in
            WordNormalization(input: word, lemma: word, status: .canonical, reason: "", cached: true)
        },
        register: @escaping WordRegisterStore.RegisterClient = { _, _ in
            WordRegistrationResult(cached: false, firstMeaning: nil)
        }
    ) -> WordRegisterStore {
        let store = WordRegisterStore(
            messageText: messageText, normalizeClient: normalize, registerClient: register)
        store.normalizeDebounce = .zero
        return store
    }

    func testToggleTokenSetsCandidateAndDeselectClears() async {
        let store = makeStore(messageText: "I picked it up.")
        store.toggleToken(at: 1)
        XCTAssertEqual(store.candidateText, "picked")
        await store.normalizeTask?.value
        store.toggleToken(at: 1)
        XCTAssertEqual(store.candidateText, "")
        XCTAssertNil(store.suggestionNote)
    }

    func testNormalizationSuggestionReplacesCandidate() async {
        let store = makeStore(
            messageText: "I picked it up yesterday.",
            normalize: { word, context in
                XCTAssertEqual(word, "picked")
                // 文脈は発話全文（240 字以内なのでそのまま）
                XCTAssertEqual(context, "I picked it up yesterday.")
                return WordNormalization(
                    input: word, lemma: "pick up", status: .phrasePart,
                    reason: "文中の『picked』は句動詞『pick up』の一部です", cached: false)
            })
        store.toggleToken(at: 1)
        await store.normalizeTask?.value
        XCTAssertEqual(store.candidateText, "pick up")
        XCTAssertEqual(store.suggestionNote, "文中の『picked』は句動詞『pick up』の一部です")
        XCTAssertFalse(store.isNormalizing)
    }

    func testCanonicalKeepsSelectedWordAndNoNote() async {
        let store = makeStore(messageText: "Just run every day.")
        store.toggleToken(at: 1)
        await store.normalizeTask?.value
        XCTAssertEqual(store.candidateText, "run")
        XCTAssertNil(store.suggestionNote)
    }

    /// 選択を連打しても最後の選択の結果だけが候補に残る（古い応答は世代ガードで捨てる）。
    func testLatestSelectionWins() async {
        let store = makeStore(
            messageText: "He talked and walked.",
            normalize: { word, _ in
                WordNormalization(
                    input: word, lemma: word == "talked" ? "talk" : "walk",
                    status: .inflected, reason: "原形化", cached: false)
            })
        store.toggleToken(at: 1)  // talked
        store.toggleToken(at: 1)  // 解除
        store.toggleToken(at: 3)  // walked
        await store.normalizeTask?.value
        XCTAssertEqual(store.candidateText, "walk")
    }

    /// 正規化 API の失敗は提案が出ないだけで、選択語のまま登録に進める。
    func testNormalizeFailureKeepsCandidate() async {
        let store = makeStore(
            messageText: "I picked it up.",
            normalize: { _, _ in throw WordBookError.invalidResponse })
        store.toggleToken(at: 1)
        await store.normalizeTask?.value
        XCTAssertEqual(store.candidateText, "picked")
        XCTAssertNil(store.errorText)
        XCTAssertFalse(store.isNormalizing)
    }

    // MARK: - 登録

    func testRegisterNormalizesWordAndReportsNew() async {
        var sentWord: String?
        var sentContext: String?
        var registeredCallbackCount = 0
        let store = makeStore(
            messageText: "I finally got around to it.",
            register: { word, context in
                sentWord = word
                sentContext = context
                return WordRegistrationResult(cached: false, firstMeaning: "ようやく〜する")
            })
        store.onRegistered = { registeredCallbackCount += 1 }
        store.candidateText = "  Get  Around to "
        await store.register()
        // 単語帳の既存キー規則（小文字 + 空白畳み込み）で送る
        XCTAssertEqual(sentWord, "get around to")
        // 登録の文脈は発話全文
        XCTAssertEqual(sentContext, "I finally got around to it.")
        XCTAssertEqual(store.resultText, "「get around to」を登録しました（ようやく〜する）")
        XCTAssertEqual(registeredCallbackCount, 1)
        XCTAssertNil(store.errorText)
    }

    func testRegisterCachedWordDoesNotFireCallback() async {
        var registeredCallbackCount = 0
        let store = makeStore(
            messageText: "run",
            register: { _, _ in WordRegistrationResult(cached: true, firstMeaning: "走る") })
        store.onRegistered = { registeredCallbackCount += 1 }
        store.candidateText = "run"
        await store.register()
        XCTAssertEqual(store.resultText, "「run」はすでに単語帳にあります（走る）")
        XCTAssertEqual(registeredCallbackCount, 0)
    }

    func testRegisterFailureShowsError() async {
        let store = makeStore(
            messageText: "run",
            register: { _, _ in throw WordBookError.missingSecret })
        store.candidateText = "run"
        await store.register()
        XCTAssertNil(store.resultText)
        XCTAssertEqual(store.errorText, WordBookError.missingSecret.errorDescription)
        XCTAssertFalse(store.isRegistering)
    }

    // MARK: - Phase 4: 基本形での登録の保証（docs/plans/tap-word-registration.md）

    /// サーバが phrase のまま lemma だけ直して返すケース（makes sense → make sense）でも
    /// 候補が置き換わる（status ではなく lemma の差で適用する）。
    func testPhraseWithCorrectedLemmaReplacesCandidate() async {
        let store = makeStore(
            messageText: "That makes sense to me.",
            normalize: { word, _ in
                WordNormalization(
                    input: word, lemma: "make sense", status: .phrase, reason: "", cached: false)
            })
        store.toggleToken(at: 1)  // makes
        store.toggleToken(at: 2)  // sense
        await store.normalizeTask?.value
        XCTAssertEqual(store.candidateText, "make sense")
        // reason が空でも何が起きたか分かる一般文を出す
        XCTAssertEqual(store.suggestionNote, "基本形「make sense」に直しました")
    }

    /// 正規化の完了前に登録をタップしても、提案を待ってから基本形で登録される。
    func testRegisterWaitsForInFlightNormalization() async {
        var registeredWord: String?
        let store = makeStore(
            messageText: "That makes sense to me.",
            normalize: { word, _ in
                try? await Task.sleep(for: .milliseconds(50))
                return WordNormalization(
                    input: word, lemma: "make sense", status: .phrase, reason: "", cached: false)
            },
            register: { word, _ in
                registeredWord = word
                return WordRegistrationResult(cached: false, firstMeaning: nil)
            })
        store.toggleToken(at: 1)
        store.toggleToken(at: 2)
        // 正規化タスクを待たずに即登録（実機の速いタップ相当）
        await store.register()
        XCTAssertEqual(registeredWord, "make sense")
        XCTAssertEqual(
            store.resultText,
            "「makes sense」を基本形「make sense」に直しました。「make sense」を登録しました")
    }

    /// 選択時の正規化が失敗していたら、登録前にもう一度だけ正規化してから送る。
    func testRegisterRetriesNormalizationBeforeSubmit() async {
        var normalizeCalls = 0
        var registeredWord: String?
        let store = makeStore(
            messageText: "I picked it up.",
            normalize: { word, _ in
                normalizeCalls += 1
                if normalizeCalls == 1 { throw WordBookError.invalidResponse }
                return WordNormalization(
                    input: word, lemma: "pick", status: .inflected, reason: "過去形", cached: false)
            },
            register: { word, _ in
                registeredWord = word
                return WordRegistrationResult(cached: false, firstMeaning: nil)
            })
        store.toggleToken(at: 1)  // picked（1 回目の正規化は失敗）
        await store.normalizeTask?.value
        await store.register()
        XCTAssertEqual(normalizeCalls, 2)
        XCTAssertEqual(registeredWord, "pick")
        XCTAssertEqual(store.resultText, "「picked」を基本形「pick」に直しました。「pick」を登録しました")
    }

    /// 正規化適用済みの候補で登録しても追加の正規化 API 呼び出しはしない。
    func testRegisterSkipsNormalizationWhenAlreadyNormalized() async {
        var normalizeCalls = 0
        let store = makeStore(
            messageText: "I picked it up.",
            normalize: { word, _ in
                normalizeCalls += 1
                return WordNormalization(
                    input: word, lemma: "pick", status: .inflected, reason: "過去形", cached: false)
            })
        store.toggleToken(at: 1)
        await store.normalizeTask?.value
        XCTAssertEqual(store.candidateText, "pick")
        await store.register()
        XCTAssertEqual(normalizeCalls, 1)
    }

    /// 手動編集した候補は再正規化せずそのまま登録する（変化形をあえて登録する逃げ道）。
    func testRegisterKeepsManuallyEditedCandidate() async {
        var normalizeCalls = 0
        var registeredWord: String?
        let store = makeStore(
            messageText: "I picked it up.",
            normalize: { word, _ in
                normalizeCalls += 1
                return WordNormalization(
                    input: word, lemma: "pick", status: .inflected, reason: "過去形", cached: false)
            },
            register: { word, _ in
                registeredWord = word
                return WordRegistrationResult(cached: false, firstMeaning: nil)
            })
        store.toggleToken(at: 1)
        await store.normalizeTask?.value
        // 提案（pick）をユーザーが picked に戻した
        store.candidateText = "picked"
        XCTAssertTrue(store.isCandidateManuallyEdited)
        await store.register()
        XCTAssertEqual(normalizeCalls, 1)
        XCTAssertEqual(registeredWord, "picked")
        XCTAssertEqual(store.resultText, "「picked」を登録しました")
    }

    /// 登録前の正規化も失敗したら候補のまま登録する（登録は止めない）。
    func testRegisterProceedsRawWhenNormalizationKeepsFailing() async {
        var registeredWord: String?
        let store = makeStore(
            messageText: "I picked it up.",
            normalize: { _, _ in throw WordBookError.invalidResponse },
            register: { word, _ in
                registeredWord = word
                return WordRegistrationResult(cached: false, firstMeaning: nil)
            })
        store.toggleToken(at: 1)
        await store.normalizeTask?.value
        await store.register()
        XCTAssertEqual(registeredWord, "picked")
        XCTAssertEqual(store.resultText, "「picked」を登録しました")
        XCTAssertNil(store.errorText)
    }

    func testRegisterRejectsEmptyAndTooLongWord() async {
        var called = false
        let store = makeStore(
            messageText: "x",
            register: { _, _ in
                called = true
                return WordRegistrationResult(cached: false, firstMeaning: nil)
            })
        store.candidateText = "   "
        await store.register()
        XCTAssertFalse(called)

        store.candidateText = String(repeating: "a", count: WordRegisterStore.wordMaxLength + 1)
        await store.register()
        XCTAssertFalse(called)
        XCTAssertNotNil(store.errorText)
    }
}
