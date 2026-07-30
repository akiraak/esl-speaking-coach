import Foundation

/// 単語帳（esl.chobi.me）の 1 語。API のレスポンス型をそのまま UI に流さない自前モデル
/// （docs/plans/wordbook-word-picker.md）。
struct WordBookEntry: Sendable, Equatable, Identifiable {
    /// 正規化済み（trim + 小文字）の語。単語帳内で一意なので ID を兼ねる
    let word: String
    /// 第 1 義（壊れた行は null で来る）
    let meaning: String?
    let partOfSpeech: String?
    let cefrLevel: String?

    var id: String { word }
}

/// `GET /api/words` の 1 ページ。`total` は検索条件込みの全件数（ページングの終端判定に使う）。
struct WordBookPage: Sendable, Equatable {
    let total: Int
    let words: [WordBookEntry]
}

/// 単語帳 1 語の詳細（`GET /api/words/:word` の `wordInfo` 全項目）。
/// null / 空配列はそのまま保持し、表示側でセクションごと畳む（docs/plans/wordbook-word-detail.md）。
struct WordBookWordDetail: Sendable, Equatable {
    struct Sense: Sendable, Equatable {
        /// 母語（日本語）での語義
        let meaning: String
        let englishDefinition: String
        let partOfSpeech: String
        let note: String?
    }

    struct Pronunciation: Sendable, Equatable {
        /// IPA（熟語は全体を 1 組のスラッシュで囲む）
        let ipa: String
        /// 音節区切り（dis-uh-BIL-uh-tee）。熟語は null
        let syllables: String?
    }

    struct Inflection: Sendable, Equatable {
        /// 活用の種類（plural / past など）
        let form: String
        let text: String
    }

    struct Example: Sendable, Equatable {
        let english: String
        let translation: String
    }

    /// 正規化済み（trim + 小文字）の語
    let word: String
    let senses: [Sense]
    let pronunciation: Pronunciation
    let inflections: [Inflection]
    let examples: [Example]
    let collocations: [String]
    let synonyms: [String]
    let antonyms: [String]
    let usageNote: String?
    let cefrLevel: String?
    let etymology: String?
    let register: String?
    let commonMistakes: String?
}

enum WordBookError: Error, LocalizedError {
    case missingSecret
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case decodingFailed
    /// 詳細 API の 404（一覧に出た直後に単語帳側で消された等）。401 / 500 と文言を混ぜない
    case wordNotFound

    var errorDescription: String? {
        switch self {
        case .missingSecret:
            return "単語帳のシークレットが未設定です。.secrets/wordbook-api-secret を用意して再インストールしてください。"
        case .invalidResponse:
            return "単語帳サーバーから不正な応答が返りました"
        case .httpError(let statusCode, let body):
            if statusCode == 401 {
                return "単語帳の認証に失敗しました（シークレットが違います）"
            }
            return "HTTP \(statusCode): \(body.prefix(300))"
        case .decodingFailed:
            return "単語帳の応答を解釈できませんでした"
        case .wordNotFound:
            return "単語帳にこの単語の詳細がありません"
        }
    }
}

/// 単語帳（esl-learning-assistant / esl.chobi.me）の読み取り専用 API クライアント。
/// 認証は `X-API-Secret` ヘッダ（生の共有シークレット）。AI は呼ばれないので課金・usage 記録はない。
/// base URL と targetLanguage=ja は自分専用アプリの既存流儀どおりハードコード。
struct WordBookClient: Sendable {
    static var baseURL: URL {
        #if DEBUG
        // ローカル backend（esl-learning-assistant を run-server.sh で起動）に向けた E2E 用
        if let override = DebugLaunchArguments.wordBookBaseURLOverride {
            return override
        }
        #endif
        return URL(string: "https://esl.chobi.me")!
    }
    static let targetLanguage = "ja"
    /// 1 ページの件数（サーバ既定 100・上限 500。ピッカーの追い読み単位）
    static let pageSize = 100
    /// 全件取得（ランダム出題）の 1 ページの件数。サーバ上限に合わせて往復を減らす
    static let allWordsPageSize = 500
    /// 全件取得の最大ページ数（取得中に total が動き続けても止まる安全弁。500 語 × 20 = 1 万語まで）
    static let allWordsMaxPages = 20

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    /// 単語帳を 1 ページ取得する。`query` は空なら送らない（全件を新しい順で返す）。
    func fetchWords(
        secret: String, query: String, offset: Int, limit: Int = pageSize
    ) async throws -> WordBookPage {
        let request = Self.makeRequest(secret: secret, query: query, offset: offset, limit: limit)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw WordBookError.invalidResponse
        }
        guard let http = response as? HTTPURLResponse else {
            throw WordBookError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw WordBookError.httpError(
                statusCode: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? "")
        }
        return try Self.parseResponse(data)
    }

    /// 1 語の詳細を取得する。404 は `wordNotFound`（一覧と違い「無い」が正常系に近いため専用ケース）。
    func fetchWordDetail(secret: String, word: String) async throws -> WordBookWordDetail {
        let request = Self.makeDetailRequest(secret: secret, word: word)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw WordBookError.invalidResponse
        }
        guard let http = response as? HTTPURLResponse else {
            throw WordBookError.invalidResponse
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 404 {
                throw WordBookError.wordNotFound
            }
            throw WordBookError.httpError(
                statusCode: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? "")
        }
        return try Self.parseDetailResponse(data)
    }

    /// 単語帳を全件取得する（ランダム出題用。docs/plans/wordbook-random-word.md）。
    /// `allWordsPageSize` の offset 追い読みで結合する。個人単語帳（数百語）前提の一括取得。
    func fetchAllWords(secret: String) async throws -> [WordBookEntry] {
        try await Self.fetchAllWords { offset in
            try await fetchWords(
                secret: secret, query: "", offset: offset, limit: Self.allWordsPageSize)
        }
    }

    /// 全件取得のページ結合（テストから fetchPage を差し替える）。
    /// 取得中に単語帳側が更新されて total が動いても止まるよう、
    /// 空ページ・`allWordsMaxPages` で打ち切る。重複した word は先勝ちで畳む
    /// （word は一覧の ID。重複させると SwiftUI の ForEach が壊れるピッカーと同じ扱い）。
    static func fetchAllWords(
        fetchPage: (_ offset: Int) async throws -> WordBookPage
    ) async throws -> [WordBookEntry] {
        var entries: [WordBookEntry] = []
        var seen = Set<String>()
        var offset = 0
        for _ in 0..<allWordsMaxPages {
            let page = try await fetchPage(offset)
            guard !page.words.isEmpty else { break }
            offset += page.words.count
            for entry in page.words where seen.insert(entry.word).inserted {
                entries.append(entry)
            }
            if offset >= page.total { break }
        }
        return entries
    }

    /// リクエストを組み立てる。テストから直接検証できるよう static にしてある。
    /// クエリの percent-encode は URLQueryItem に任せる（熟語のスペースも正しく載る）。
    static func makeRequest(
        secret: String, query: String, offset: Int, limit: Int = pageSize
    ) -> URLRequest {
        var components = URLComponents(
            url: baseURL.appending(path: "/api/words"), resolvingAgainstBaseURL: false)!
        var queryItems = [
            URLQueryItem(name: "targetLanguage", value: targetLanguage),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(max(0, offset))),
        ]
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            queryItems.append(URLQueryItem(name: "q", value: trimmed))
        }
        components.queryItems = queryItems
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue(secret, forHTTPHeaderField: "X-API-Secret")
        return request
    }

    /// レスポンス JSON をページへ変換する。`meaning` 等の null は許容（壊れた行はエラーにならない仕様）。
    static func parseResponse(_ data: Data) throws -> WordBookPage {
        guard let payload = try? JSONDecoder().decode(ResponsePayload.self, from: data) else {
            throw WordBookError.decodingFailed
        }
        let entries = payload.words.map {
            WordBookEntry(
                word: $0.word,
                meaning: $0.meaning,
                partOfSpeech: $0.partOfSpeech,
                cefrLevel: $0.cefrLevel)
        }
        return WordBookPage(total: payload.total, words: entries)
    }

    private struct ResponsePayload: Decodable {
        let total: Int
        let words: [WordPayload]

        struct WordPayload: Decodable {
            let word: String
            let meaning: String?
            let partOfSpeech: String?
            let cefrLevel: String?
        }
    }

    /// 詳細リクエストを組み立てる。語はパスコンポーネントに載せ、percent-encode は
    /// `appending(path:)` に任せる（熟語のスペースが `even%20though` になる。テストで固定）。
    static func makeDetailRequest(secret: String, word: String) -> URLRequest {
        var url = baseURL
            .appending(path: "/api/words")
            .appending(path: word)
        url.append(queryItems: [URLQueryItem(name: "targetLanguage", value: targetLanguage)])
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(secret, forHTTPHeaderField: "X-API-Secret")
        return request
    }

    /// 詳細レスポンス JSON をモデルへ変換する。契約上 nullable な項目（note / syllables /
    /// usageNote 等）だけ nil を許し、必須項目が欠けた応答は `decodingFailed` にする。
    /// ルート外のメタ（model / generationCount）は学習に不要なので落とす。
    static func parseDetailResponse(_ data: Data) throws -> WordBookWordDetail {
        guard let payload = try? JSONDecoder().decode(DetailResponsePayload.self, from: data) else {
            throw WordBookError.decodingFailed
        }
        let info = payload.wordInfo
        return WordBookWordDetail(
            word: payload.word,
            senses: info.senses.map {
                WordBookWordDetail.Sense(
                    meaning: $0.meaning,
                    englishDefinition: $0.englishDefinition,
                    partOfSpeech: $0.partOfSpeech,
                    note: $0.note)
            },
            pronunciation: WordBookWordDetail.Pronunciation(
                ipa: info.pronunciation.ipa,
                syllables: info.pronunciation.syllables),
            inflections: info.inflections.map {
                WordBookWordDetail.Inflection(form: $0.form, text: $0.text)
            },
            examples: info.examples.map {
                WordBookWordDetail.Example(english: $0.english, translation: $0.translation)
            },
            collocations: info.collocations,
            synonyms: info.synonyms,
            antonyms: info.antonyms,
            usageNote: info.usageNote,
            cefrLevel: info.cefrLevel,
            etymology: info.etymology,
            register: info.register,
            commonMistakes: info.commonMistakes)
    }

    private struct DetailResponsePayload: Decodable {
        let word: String
        let wordInfo: WordInfoPayload

        struct WordInfoPayload: Decodable {
            let senses: [SensePayload]
            let pronunciation: PronunciationPayload
            let inflections: [InflectionPayload]
            let examples: [ExamplePayload]
            let collocations: [String]
            let synonyms: [String]
            let antonyms: [String]
            let usageNote: String?
            let cefrLevel: String?
            let etymology: String?
            let register: String?
            let commonMistakes: String?
        }

        struct SensePayload: Decodable {
            let meaning: String
            let englishDefinition: String
            let partOfSpeech: String
            let note: String?
        }

        struct PronunciationPayload: Decodable {
            let ipa: String
            let syllables: String?
        }

        struct InflectionPayload: Decodable {
            let form: String
            let text: String
        }

        struct ExamplePayload: Decodable {
            let english: String
            let translation: String
        }
    }
}
