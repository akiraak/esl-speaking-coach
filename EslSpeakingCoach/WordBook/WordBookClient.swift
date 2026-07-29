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

enum WordBookError: Error, LocalizedError {
    case missingSecret
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case decodingFailed

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

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    /// 単語帳を 1 ページ取得する。`query` は空なら送らない（全件を新しい順で返す）。
    func fetchWords(secret: String, query: String, offset: Int) async throws -> WordBookPage {
        let request = Self.makeRequest(secret: secret, query: query, offset: offset)
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

    /// リクエストを組み立てる。テストから直接検証できるよう static にしてある。
    /// クエリの percent-encode は URLQueryItem に任せる（熟語のスペースも正しく載る）。
    static func makeRequest(secret: String, query: String, offset: Int) -> URLRequest {
        var components = URLComponents(
            url: baseURL.appending(path: "/api/words"), resolvingAgainstBaseURL: false)!
        var queryItems = [
            URLQueryItem(name: "targetLanguage", value: targetLanguage),
            URLQueryItem(name: "limit", value: String(pageSize)),
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
}
