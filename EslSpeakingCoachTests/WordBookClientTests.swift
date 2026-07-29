import XCTest
@testable import EslSpeakingCoach

final class WordBookClientTests: XCTestCase {
    // MARK: - makeRequest

    func testMakeRequestBuildsURLAndHeader() throws {
        let request = WordBookClient.makeRequest(secret: "test-secret_1234567890", query: "", offset: 0)
        let url = try XCTUnwrap(request.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "esl.chobi.me")
        XCTAssertEqual(components.path, "/api/words")
        XCTAssertEqual(request.httpMethod, "GET")
        // 認証は生の共有シークレット（Bearer プレフィックスなし）
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Secret"), "test-secret_1234567890")

        let items = try XCTUnwrap(components.queryItems)
        XCTAssertEqual(items.first { $0.name == "targetLanguage" }?.value, "ja")
        XCTAssertEqual(items.first { $0.name == "limit" }?.value, String(WordBookClient.pageSize))
        XCTAssertEqual(items.first { $0.name == "offset" }?.value, "0")
        // 空クエリのとき q は送らない（全件を新しい順で返す）
        XCTAssertNil(items.first { $0.name == "q" })
    }

    /// 熟語（スペース入り）の検索クエリが percent-encode されて載る。
    func testMakeRequestEncodesPhraseQuery() throws {
        let request = WordBookClient.makeRequest(
            secret: "s", query: "  get around to ", offset: 200)
        let url = try XCTUnwrap(request.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = try XCTUnwrap(components.queryItems)
        // 前後の空白は落とし、語中のスペースはそのまま検索語として送る
        XCTAssertEqual(items.first { $0.name == "q" }?.value, "get around to")
        XCTAssertEqual(items.first { $0.name == "offset" }?.value, "200")
        XCTAssertTrue(url.absoluteString.contains("q=get%20around%20to"))
    }

    // MARK: - parseResponse

    func testParseResponseExtractsPage() throws {
        let json = """
        {
          "total": 2, "limit": 100, "offset": 0,
          "words": [
            {
              "word": "get around to", "targetLanguage": "ja",
              "meaning": "〜する時間を見つける", "partOfSpeech": "phrasal verb",
              "cefrLevel": "B2",
              "createdAt": "2026-07-01T00:00:00.000Z", "updatedAt": "2026-07-20T00:00:00.000Z"
            },
            {
              "word": "resilient", "targetLanguage": "ja",
              "meaning": "回復力のある", "partOfSpeech": "adjective", "cefrLevel": "C1",
              "createdAt": "2026-07-02T00:00:00.000Z", "updatedAt": "2026-07-19T00:00:00.000Z"
            }
          ]
        }
        """
        let page = try WordBookClient.parseResponse(Data(json.utf8))
        XCTAssertEqual(page.total, 2)
        XCTAssertEqual(page.words.count, 2)
        XCTAssertEqual(page.words[0].word, "get around to")
        XCTAssertEqual(page.words[0].meaning, "〜する時間を見つける")
        XCTAssertEqual(page.words[0].partOfSpeech, "phrasal verb")
        XCTAssertEqual(page.words[0].cefrLevel, "B2")
    }

    /// 壊れた行は meaning 等が null で来る（API はエラーにしない仕様）。落とさず nil で保持する。
    func testParseResponseAllowsNullFields() throws {
        let json = """
        {
          "total": 1, "limit": 100, "offset": 0,
          "words": [
            {
              "word": "serendipity", "targetLanguage": "ja",
              "meaning": null, "partOfSpeech": null, "cefrLevel": null,
              "createdAt": "2026-07-01T00:00:00.000Z", "updatedAt": "2026-07-20T00:00:00.000Z"
            }
          ]
        }
        """
        let page = try WordBookClient.parseResponse(Data(json.utf8))
        XCTAssertEqual(page.words.count, 1)
        XCTAssertEqual(page.words[0].word, "serendipity")
        XCTAssertNil(page.words[0].meaning)
        XCTAssertNil(page.words[0].partOfSpeech)
        XCTAssertNil(page.words[0].cefrLevel)
    }

    func testParseResponseEmptyPage() throws {
        let page = try WordBookClient.parseResponse(
            Data(#"{"total":0,"limit":100,"offset":0,"words":[]}"#.utf8))
        XCTAssertEqual(page.total, 0)
        XCTAssertTrue(page.words.isEmpty)
    }

    func testParseResponseThrowsOnMalformedJSON() {
        XCTAssertThrowsError(try WordBookClient.parseResponse(Data("not json".utf8))) { error in
            guard case WordBookError.decodingFailed = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        // 401 のボディ（{"error":"unauthorized"}）が 200 で来るような想定外もデコード失敗として扱う
        XCTAssertThrowsError(
            try WordBookClient.parseResponse(Data(#"{"error":"unauthorized"}"#.utf8)))
    }

    // MARK: - エラー文言

    func testUnauthorizedErrorMessageMentionsSecret() {
        let error = WordBookError.httpError(statusCode: 401, body: #"{"error":"unauthorized"}"#)
        XCTAssertEqual(error.errorDescription, "単語帳の認証に失敗しました（シークレットが違います）")
    }
}
