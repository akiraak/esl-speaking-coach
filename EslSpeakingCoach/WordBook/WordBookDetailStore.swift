import Foundation
import Observation

/// 単語詳細画面の状態（docs/plans/wordbook-word-detail.md）。
/// 画面を開くたびに作り直して取得する（一覧と同じ流儀。ローカルキャッシュはしない）。
@MainActor
@Observable
final class WordBookDetailStore {
    enum State: Equatable {
        case loading
        case loaded(WordBookWordDetail)
        /// 取得失敗（再試行ボタンを出す）。404 は `WordBookError.wordNotFound` の文言になる
        case failed(String)
    }

    /// 表示対象の語（一覧で選んだ正規化済みキー）
    let word: String
    private(set) var state: State = .loading

    private let fetchDetail: @Sendable (String) async throws -> WordBookWordDetail
    private var didLoadInitial = false

    /// fetchDetail を差し替えて単体テストする。既定はシークレットを Keychain から読んで実 API を叩く。
    init(
        word: String,
        fetchDetail: (@Sendable (String) async throws -> WordBookWordDetail)? = nil
    ) {
        self.word = word
        self.fetchDetail = fetchDetail ?? { word in
            guard
                let secret = (try? KeychainStore().read(
                    account: KeychainStore.wordBookAPISecretAccount)) ?? nil,
                !secret.isEmpty
            else {
                throw WordBookError.missingSecret
            }
            return try await WordBookClient().fetchWordDetail(secret: secret, word: word)
        }
    }

    /// 画面表示時の初回取得（pop で戻って view の task が走り直しても二重には取らない）。
    func loadInitial() async {
        guard !didLoadInitial else { return }
        didLoadInitial = true
        await load()
    }

    /// 再試行ボタン。
    func retry() async {
        await load()
    }

    private func load() async {
        state = .loading
        do {
            state = .loaded(try await fetchDetail(word))
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    private static func message(for error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription {
            return localized
        }
        return "単語の詳細を取得できませんでした: \(error.localizedDescription)"
    }
}
