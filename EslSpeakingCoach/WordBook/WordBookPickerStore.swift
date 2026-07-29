import Foundation
import Observation

/// 単語帳ピッカーシートの状態（docs/plans/wordbook-word-picker.md）。
/// シートを開くたびに作り直して取得する（ローカルキャッシュ・差分同期はしない）。
/// 検索はサーバの `q`（デバウンス付き）、ページングは `offset` の追い読み。
@MainActor
@Observable
final class WordBookPickerStore {
    enum State: Equatable {
        /// 初回・検索での取得中（リストは空）
        case loading
        /// entries 表示中（追い読み中は `isLoadingMore`）
        case loaded
        /// 取得失敗（再試行ボタンを出す）
        case failed(String)
    }

    private(set) var state: State = .loading
    private(set) var entries: [WordBookEntry] = []
    /// 現在の検索条件での全件数（ページングの終端判定）
    private(set) var total = 0
    private(set) var isLoadingMore = false
    /// 追い読みだけが失敗したとき true（リストは壊さず、末尾に再試行ボタンを出す）
    private(set) var loadMoreFailed = false

    /// 検索フィールドの入力。変更のたびにデバウンスして取り直す
    var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            searchTask?.cancel()
            searchTask = Task { [debounceInterval] in
                try? await Task.sleep(for: debounceInterval)
                guard !Task.isCancelled else { return }
                await reload()
            }
        }
    }

    /// デバウンス中の検索タスク（テストから完了を待つために internal に出している）
    private(set) var searchTask: Task<Void, Never>?

    var canLoadMore: Bool {
        state == .loaded && entries.count < total
    }

    private let fetchPage: @Sendable (_ query: String, _ offset: Int) async throws -> WordBookPage
    private let debounceInterval: Duration
    /// 取り直しのたびに進める世代。古い応答（検索中に返ってきた前の条件の結果）を捨てる
    private var generation = 0
    private var didLoadInitial = false

    /// fetchPage を差し替えて単体テストする。既定はシークレットを Keychain から読んで実 API を叩く。
    init(
        fetchPage: (@Sendable (String, Int) async throws -> WordBookPage)? = nil,
        debounceInterval: Duration = .milliseconds(300)
    ) {
        self.debounceInterval = debounceInterval
        self.fetchPage = fetchPage ?? { query, offset in
            guard
                let secret = (try? KeychainStore().read(
                    account: KeychainStore.wordBookAPISecretAccount)) ?? nil,
                !secret.isEmpty
            else {
                throw WordBookError.missingSecret
            }
            return try await WordBookClient().fetchWords(
                secret: secret, query: query, offset: offset)
        }
    }

    /// シート表示時の初回取得（再表示で view の task が走り直しても二重には取らない）。
    func loadInitial() async {
        guard !didLoadInitial else { return }
        didLoadInitial = true
        await reload()
    }

    /// 再試行ボタン。現在の検索条件で最初のページから取り直す。
    func retry() async {
        await reload()
    }

    /// 最初のページから取り直す（初回・検索・再試行の共通経路)。
    func reload() async {
        generation += 1
        let current = generation
        state = .loading
        entries = []
        total = 0
        isLoadingMore = false
        loadMoreFailed = false
        do {
            let page = try await fetchPage(searchText, 0)
            guard generation == current else { return }
            entries = page.words
            total = page.total
            state = .loaded
        } catch {
            guard generation == current else { return }
            state = .failed(Self.message(for: error))
        }
    }

    /// リスト末尾到達で次のページを追い読みする。失敗してもリストは保ち、再試行できるようにする。
    func loadMore() async {
        guard canLoadMore, !isLoadingMore else { return }
        let current = generation
        isLoadingMore = true
        loadMoreFailed = false
        defer { isLoadingMore = false }
        do {
            let page = try await fetchPage(searchText, entries.count)
            guard generation == current else { return }
            // offset ページング中に単語帳側が更新されると重複が返り得る。
            // word は一覧の ID なので重複させない（SwiftUI の ForEach が壊れる）
            let existing = Set(entries.map(\.word))
            entries += page.words.filter { !existing.contains($0.word) }
            total = page.total
        } catch {
            guard generation == current else { return }
            loadMoreFailed = true
        }
    }

    private static func message(for error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription {
            return localized
        }
        return "単語帳を取得できませんでした: \(error.localizedDescription)"
    }
}
