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

/// 選択語の正規化結果（`POST /api/word-normalize`）。
/// backend の WordNormalization（wordNormalize.ts）と同構造。status で確認 UI の出し分けを決める。
struct WordNormalization: Sendable, Equatable {
    enum Status: String, Sendable {
        /// 既に辞書見出し語（lemma は入力と同じ・reason は空）
        case canonical
        /// 語形変化（lemma は原形）
        case inflected
        /// 綴り間違い（lemma は正しい綴りの原形）
        case misspelled
        /// 固有名詞（訂正しない）
        case properNoun = "proper_noun"
        /// 既に基本形の複数語連語（句動詞・イディオム）
        case phrase
        /// タップ語が文中の複数語表現の一部（lemma は表現全体。例: "up" → "look up"）
        case phrasePart = "phrase_part"
        /// 判定不能・英語でない
        case unknown
    }

    let input: String
    /// 登録すべき辞書見出し語（canonical / proper_noun / phrase / unknown では入力と同じ）
    let lemma: String
    let status: Status
    /// 訂正理由（日本語 1 文）。canonical / proper_noun / phrase / unknown は空文字で来る
    let reason: String
    let cached: Bool
}

/// 登録結果（`POST /api/word-info`）。wordInfo 全体は使わず結果表示に要る最小限だけ持つ。
struct WordRegistrationResult: Sendable, Equatable {
    /// true = 既に単語帳にあった（サーバは AI を呼ばず保存済みを返す）
    let cached: Bool
    /// 第 1 義（結果表示用。応答に無ければ nil）
    let firstMeaning: String?
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

/// 単語帳（esl-learning-assistant / esl.chobi.me）の API クライアント。
/// 認証は `X-API-Secret` ヘッダ（生の共有シークレット。読み書き同一）。
/// 一覧・詳細（GET）は AI を呼ばないが、正規化・登録（POST）はサーバ側で AI が動く
/// （課金はサーバ側の管理で、本アプリの usage 記録の対象外。docs/plans/tap-word-registration.md）。
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

    /// 正規化・登録（POST）用。サーバ側で AI 生成を同期で待つため（体感 5〜20 秒）、
    /// 一覧用より大きいタイムアウトを取る。
    private static let writeSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 120
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

    // MARK: - 正規化・登録（docs/plans/tap-word-registration.md）

    /// 選択語を辞書見出し語へ正規化する。`context` はタップ語を含む文
    /// （句動詞の一部タップ → 句全体の提案に使う。サーバ側クランプ 300 字より
    /// 手前でクライアントが 240 字に切ってから渡す）。
    func normalizeWord(
        secret: String, word: String, context: String?
    ) async throws -> WordNormalization {
        let request = Self.makeNormalizeRequest(secret: secret, word: word, context: context)
        let data = try await Self.postData(request)
        return try Self.parseNormalization(data)
    }

    /// 単語帳へ登録する（`POST /api/word-info`）。サーバ側で語義を AI 生成して保存する。
    /// 既に登録済みなら AI を呼ばず既存データが `cached: true` で返る（エラーにならない）。
    /// `context` は発話全文（その会話での意味に合った語義を作らせる。サーバ側クランプ 8000 字）。
    func registerWord(
        secret: String, word: String, context: String?
    ) async throws -> WordRegistrationResult {
        let request = Self.makeRegisterRequest(secret: secret, word: word, context: context)
        let data = try await Self.postData(request)
        return try Self.parseRegistration(data)
    }

    /// POST 共通の送受信（`writeSession` + ステータス検査）。
    private static func postData(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await writeSession.data(for: request)
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
        return data
    }

    /// POST リクエストのボディ（両 API 共通の 3 項目。nil の context は JSON から落ちる）。
    private struct PostBody: Encodable {
        let word: String
        let targetLanguage: String
        let context: String?
    }

    static func makeNormalizeRequest(secret: String, word: String, context: String?) -> URLRequest {
        makePostRequest(path: "/api/word-normalize", secret: secret, word: word, context: context)
    }

    static func makeRegisterRequest(secret: String, word: String, context: String?) -> URLRequest {
        makePostRequest(path: "/api/word-info", secret: secret, word: word, context: context)
    }

    private static func makePostRequest(
        path: String, secret: String, word: String, context: String?
    ) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue(secret, forHTTPHeaderField: "X-API-Secret")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(
            PostBody(word: word, targetLanguage: targetLanguage, context: context))
        return request
    }

    /// 正規化レスポンスをモデルへ変換する。未知の status は `unknown` に畳む
    /// （サーバ側の分類が増えても提案なし扱いで壊れない）。
    static func parseNormalization(_ data: Data) throws -> WordNormalization {
        guard let payload = try? JSONDecoder().decode(NormalizePayload.self, from: data) else {
            throw WordBookError.decodingFailed
        }
        return WordNormalization(
            input: payload.input,
            lemma: payload.lemma,
            status: WordNormalization.Status(rawValue: payload.status) ?? .unknown,
            reason: payload.reason ?? "",
            cached: payload.cached)
    }

    private struct NormalizePayload: Decodable {
        let input: String
        let lemma: String
        let status: String
        let reason: String?
        let cached: Bool
    }

    /// 登録レスポンスをモデルへ変換する。`wordInfo` は結果表示に使う第 1 義だけ拾い、
    /// 構造の細部（senses の他項目など）が変わっても壊れないよう緩く読む。
    static func parseRegistration(_ data: Data) throws -> WordRegistrationResult {
        guard let payload = try? JSONDecoder().decode(RegisterPayload.self, from: data) else {
            throw WordBookError.decodingFailed
        }
        return WordRegistrationResult(
            cached: payload.cached ?? false,
            firstMeaning: payload.wordInfo?.senses?.first?.meaning)
    }

    private struct RegisterPayload: Decodable {
        let cached: Bool?
        let wordInfo: InfoPayload?

        struct InfoPayload: Decodable {
            let senses: [SensePayload]?

            struct SensePayload: Decodable {
                let meaning: String?
            }
        }
    }
}
