import XCTest
@testable import EslSpeakingCoach

@MainActor
final class WordBookPickerStoreTests: XCTestCase {
    // MARK: - ヘルパ

    /// フェイクの単語帳（0..<count の連番語）。offset ページングをサーバと同じ挙動で返す。
    private static func makeEntries(_ range: Range<Int>) -> [WordBookEntry] {
        range.map {
            WordBookEntry(
                word: "word-\($0)", meaning: "意味 \($0)",
                partOfSpeech: nil, cefrLevel: nil)
        }
    }

    private func makeStore(
        fetchPage: @escaping @Sendable (String, Int) async throws -> WordBookPage
    ) -> WordBookPickerStore {
        WordBookPickerStore(fetchPage: fetchPage, debounceInterval: .zero)
    }

    /// 1 回だけ失敗して以後は成功するフェイク用のフラグ。
    private actor FailOnce {
        private var shouldFail = true
        func consume() -> Bool {
            defer { shouldFail = false }
            return shouldFail
        }
    }

    // MARK: - 初回読み込み・再試行

    func testLoadInitialSuccess() async {
        let words = Self.makeEntries(0..<3)
        let store = makeStore { _, _ in WordBookPage(total: 3, words: words) }
        await store.loadInitial()
        XCTAssertEqual(store.state, .loaded)
        XCTAssertEqual(store.entries, words)
        XCTAssertEqual(store.total, 3)
        XCTAssertFalse(store.canLoadMore)
    }

    /// view の task が走り直しても二重には取らない。
    func testLoadInitialRunsOnlyOnce() async {
        let counter = Counter()
        let store = makeStore { _, _ in
            await counter.increment()
            return WordBookPage(total: 0, words: [])
        }
        await store.loadInitial()
        await store.loadInitial()
        let count = await counter.value
        XCTAssertEqual(count, 1)
    }

    func testLoadFailureThenRetry() async {
        let failOnce = FailOnce()
        let words = Self.makeEntries(0..<1)
        let store = makeStore { _, _ in
            if await failOnce.consume() {
                throw WordBookError.httpError(statusCode: 500, body: "boom")
            }
            return WordBookPage(total: 1, words: words)
        }
        await store.loadInitial()
        guard case .failed(let message) = store.state else {
            return XCTFail("expected failed, got \(store.state)")
        }
        XCTAssertTrue(message.contains("500"))

        await store.retry()
        XCTAssertEqual(store.state, .loaded)
        XCTAssertEqual(store.entries, words)
    }

    /// シークレット未設定はシート内の案内文になる（.secrets の置き場所まで示す）。
    func testMissingSecretShowsGuidance() async {
        let store = makeStore { _, _ in throw WordBookError.missingSecret }
        await store.loadInitial()
        guard case .failed(let message) = store.state else {
            return XCTFail("expected failed, got \(store.state)")
        }
        XCTAssertTrue(message.contains(".secrets/wordbook-api-secret"))
    }

    // MARK: - 検索（デバウンス + リセット）

    func testSearchReloadsWithQuery() async {
        let all = Self.makeEntries(0..<5)
        let store = makeStore { query, _ in
            let hits = all.filter { query.isEmpty || $0.word.contains(query) }
            return WordBookPage(total: hits.count, words: hits)
        }
        await store.loadInitial()
        XCTAssertEqual(store.entries.count, 5)

        store.searchText = "word-3"
        await store.searchTask?.value
        XCTAssertEqual(store.state, .loaded)
        XCTAssertEqual(store.entries.map(\.word), ["word-3"])
        XCTAssertEqual(store.total, 1)
    }

    /// 連続入力では古い条件の応答を捨て、最後の検索語の結果に落ち着く（世代ガード）。
    func testRapidSearchKeepsLatestQueryResult() async {
        let all = Self.makeEntries(0..<5)
        let store = makeStore { query, _ in
            let hits = all.filter { query.isEmpty || $0.word.contains(query) }
            return WordBookPage(total: hits.count, words: hits)
        }
        await store.loadInitial()

        store.searchText = "word-1"
        let firstTask = store.searchTask
        store.searchText = "word-2"
        await firstTask?.value
        await store.searchTask?.value
        XCTAssertEqual(store.entries.map(\.word), ["word-2"])
    }

    // MARK: - ページング

    func testLoadMoreAppendsUntilTotal() async {
        let all = Self.makeEntries(0..<130)
        let store = makeStore { _, offset in
            WordBookPage(total: all.count, words: Array(all.dropFirst(offset).prefix(100)))
        }
        await store.loadInitial()
        XCTAssertEqual(store.entries.count, 100)
        XCTAssertTrue(store.canLoadMore)

        await store.loadMore()
        XCTAssertEqual(store.entries.count, 130)
        XCTAssertFalse(store.canLoadMore)

        // 終端に達したら何もしない
        await store.loadMore()
        XCTAssertEqual(store.entries.count, 130)
    }

    /// ページング中に単語帳側が更新されて同じ語が返っても、一覧の ID（word）は重複させない。
    func testLoadMoreDropsDuplicateWords() async {
        let all = Self.makeEntries(0..<120)
        let store = makeStore { _, offset in
            if offset == 0 {
                return WordBookPage(total: 120, words: Array(all.prefix(100)))
            }
            // 先頭に 1 件挿入された想定: 2 ページ目の先頭が 1 ページ目の末尾と重複する
            return WordBookPage(total: 120, words: Array(all.dropFirst(99).prefix(100)))
        }
        await store.loadInitial()
        await store.loadMore()
        XCTAssertEqual(store.entries.count, 120)
        XCTAssertEqual(Set(store.entries.map(\.word)).count, 120)
    }

    /// 追い読みの失敗はリストを壊さず、再試行で続きから読める。
    func testLoadMoreFailureKeepsListAndRetries() async {
        let failOnce = FailOnce()
        let all = Self.makeEntries(0..<130)
        let store = makeStore { _, offset in
            if offset > 0, await failOnce.consume() {
                throw WordBookError.invalidResponse
            }
            return WordBookPage(total: all.count, words: Array(all.dropFirst(offset).prefix(100)))
        }
        await store.loadInitial()
        await store.loadMore()
        XCTAssertTrue(store.loadMoreFailed)
        XCTAssertEqual(store.state, .loaded)
        XCTAssertEqual(store.entries.count, 100)

        await store.loadMore()
        XCTAssertFalse(store.loadMoreFailed)
        XCTAssertEqual(store.entries.count, 130)
    }

    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }
}
