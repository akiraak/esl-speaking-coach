import XCTest
@testable import EslSpeakingCoach

@MainActor
final class WordBookDetailStoreTests: XCTestCase {
    // MARK: - ヘルパ

    private nonisolated static func makeDetail(word: String) -> WordBookWordDetail {
        WordBookWordDetail(
            word: word,
            senses: [
                .init(
                    meaning: "障害", englishDefinition: "a condition that limits activities",
                    partOfSpeech: "noun", note: nil)
            ],
            pronunciation: .init(ipa: "/ˌdɪsəˈbɪləti/", syllables: nil),
            inflections: [],
            examples: [],
            collocations: [],
            synonyms: [],
            antonyms: [],
            usageNote: nil,
            cefrLevel: "B2",
            etymology: nil,
            register: nil,
            commonMistakes: nil)
    }

    /// 1 回だけ失敗して以後は成功するフェイク用のフラグ。
    private actor FailOnce {
        private var shouldFail = true
        func consume() -> Bool {
            defer { shouldFail = false }
            return shouldFail
        }
    }

    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    // MARK: - 読み込み・再試行

    func testLoadInitialSuccess() async {
        let detail = Self.makeDetail(word: "disability")
        let store = WordBookDetailStore(word: "disability") { word in
            XCTAssertEqual(word, "disability")
            return detail
        }
        await store.loadInitial()
        XCTAssertEqual(store.state, .loaded(detail))
    }

    /// pop から戻って view の task が走り直しても二重には取らない。
    func testLoadInitialRunsOnlyOnce() async {
        let counter = Counter()
        let store = WordBookDetailStore(word: "disability") { word in
            await counter.increment()
            return Self.makeDetail(word: word)
        }
        await store.loadInitial()
        await store.loadInitial()
        let count = await counter.value
        XCTAssertEqual(count, 1)
    }

    func testLoadFailureThenRetry() async {
        let failOnce = FailOnce()
        let detail = Self.makeDetail(word: "disability")
        let store = WordBookDetailStore(word: "disability") { _ in
            if await failOnce.consume() {
                throw WordBookError.httpError(statusCode: 500, body: "boom")
            }
            return detail
        }
        await store.loadInitial()
        guard case .failed(let message) = store.state else {
            return XCTFail("expected failed, got \(store.state)")
        }
        XCTAssertTrue(message.contains("500"))

        await store.retry()
        XCTAssertEqual(store.state, .loaded(detail))
    }

    /// 404 は 401 / 500 と混ざらない専用文言になる。
    func testWordNotFoundShowsDedicatedMessage() async {
        let store = WordBookDetailStore(word: "ghost-word") { _ in
            throw WordBookError.wordNotFound
        }
        await store.loadInitial()
        XCTAssertEqual(store.state, .failed("単語帳にこの単語の詳細がありません"))
    }

    /// シークレット未設定は .secrets の置き場所まで示す（ピッカーと同じ案内文）。
    func testMissingSecretShowsGuidance() async {
        let store = WordBookDetailStore(word: "disability") { _ in
            throw WordBookError.missingSecret
        }
        await store.loadInitial()
        guard case .failed(let message) = store.state else {
            return XCTFail("expected failed, got \(store.state)")
        }
        XCTAssertTrue(message.contains(".secrets/wordbook-api-secret"))
    }
}
