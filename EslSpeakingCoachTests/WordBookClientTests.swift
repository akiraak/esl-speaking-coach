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

    // MARK: - makeDetailRequest

    func testMakeDetailRequestBuildsURLAndHeader() throws {
        let request = WordBookClient.makeDetailRequest(secret: "test-secret_1234567890", word: "disability")
        let url = try XCTUnwrap(request.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "esl.chobi.me")
        XCTAssertEqual(components.path, "/api/words/disability")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Secret"), "test-secret_1234567890")

        let items = try XCTUnwrap(components.queryItems)
        XCTAssertEqual(items.first { $0.name == "targetLanguage" }?.value, "ja")
    }

    /// 熟語（スペース入り）はパスコンポーネントとして percent-encode される（appending(path:) の挙動を固定）。
    func testMakeDetailRequestEncodesPhraseWord() throws {
        let request = WordBookClient.makeDetailRequest(secret: "s", word: "even though")
        let url = try XCTUnwrap(request.url)
        XCTAssertTrue(url.absoluteString.contains("/api/words/even%20though"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/api/words/even though")
    }

    // MARK: - parseDetailResponse

    /// 全項目ありの応答（disability 相当）。ルート外のメタ（model / generationCount）は落とす。
    func testParseDetailResponseExtractsAllFields() throws {
        let json = """
        {
          "word": "disability", "targetLanguage": "ja",
          "wordInfo": {
            "senses": [
              {
                "meaning": "障害",
                "englishDefinition": "a physical or mental condition that limits a person's movements or activities",
                "partOfSpeech": "noun",
                "note": "身体・精神の機能に関する語"
              },
              {
                "meaning": "無能力",
                "englishDefinition": "lack of legal capacity",
                "partOfSpeech": "noun",
                "note": null
              }
            ],
            "pronunciation": { "ipa": "/ˌdɪsəˈbɪləti/", "syllables": "dis-uh-BIL-uh-tee" },
            "inflections": [ { "form": "plural", "text": "disabilities" } ],
            "examples": [
              { "english": "She has a learning disability.", "translation": "彼女には学習障害がある。" }
            ],
            "collocations": ["learning disability", "physical disability"],
            "synonyms": ["impairment", "handicap"],
            "antonyms": ["ability"],
            "usageNote": "人を主語にした表現に注意",
            "cefrLevel": "B2",
            "etymology": "dis- + ability",
            "register": "フォーマル",
            "commonMistakes": "disable（動詞）と混同しやすい"
          },
          "model": "claude-sonnet-5", "createdAt": "2026-07-01T00:00:00.000Z",
          "updatedAt": "2026-07-20T00:00:00.000Z", "generationCount": 2
        }
        """
        let detail = try WordBookClient.parseDetailResponse(Data(json.utf8))
        XCTAssertEqual(detail.word, "disability")
        XCTAssertEqual(detail.senses.count, 2)
        XCTAssertEqual(detail.senses[0].meaning, "障害")
        XCTAssertEqual(detail.senses[0].partOfSpeech, "noun")
        XCTAssertEqual(detail.senses[0].note, "身体・精神の機能に関する語")
        XCTAssertNil(detail.senses[1].note)
        XCTAssertEqual(detail.pronunciation.ipa, "/ˌdɪsəˈbɪləti/")
        XCTAssertEqual(detail.pronunciation.syllables, "dis-uh-BIL-uh-tee")
        XCTAssertEqual(detail.inflections, [.init(form: "plural", text: "disabilities")])
        XCTAssertEqual(detail.examples.count, 1)
        XCTAssertEqual(detail.examples[0].translation, "彼女には学習障害がある。")
        XCTAssertEqual(detail.collocations, ["learning disability", "physical disability"])
        XCTAssertEqual(detail.synonyms, ["impairment", "handicap"])
        XCTAssertEqual(detail.antonyms, ["ability"])
        XCTAssertEqual(detail.usageNote, "人を主語にした表現に注意")
        XCTAssertEqual(detail.cefrLevel, "B2")
        XCTAssertEqual(detail.etymology, "dis- + ability")
        XCTAssertEqual(detail.register, "フォーマル")
        XCTAssertEqual(detail.commonMistakes, "disable（動詞）と混同しやすい")
    }

    /// 熟語（even though 相当）: syllables / register 等の null と空配列は nil / [] のまま保持する。
    func testParseDetailResponseAllowsNullsAndEmptyArrays() throws {
        let json = """
        {
          "word": "even though", "targetLanguage": "ja",
          "wordInfo": {
            "senses": [
              {
                "meaning": "〜であるにもかかわらず",
                "englishDefinition": "despite the fact that",
                "partOfSpeech": "conjunction",
                "note": null
              }
            ],
            "pronunciation": { "ipa": "/ˈiːvən ðoʊ/", "syllables": null },
            "inflections": [],
            "examples": [],
            "collocations": [],
            "synonyms": ["although"],
            "antonyms": [],
            "usageNote": null,
            "cefrLevel": null,
            "etymology": null,
            "register": null,
            "commonMistakes": null
          },
          "model": "claude-sonnet-5", "createdAt": "2026-07-01T00:00:00.000Z",
          "updatedAt": "2026-07-20T00:00:00.000Z", "generationCount": 1
        }
        """
        let detail = try WordBookClient.parseDetailResponse(Data(json.utf8))
        XCTAssertEqual(detail.word, "even though")
        XCTAssertNil(detail.pronunciation.syllables)
        XCTAssertTrue(detail.inflections.isEmpty)
        XCTAssertTrue(detail.examples.isEmpty)
        XCTAssertTrue(detail.antonyms.isEmpty)
        XCTAssertNil(detail.usageNote)
        XCTAssertNil(detail.cefrLevel)
        XCTAssertNil(detail.register)
        XCTAssertNil(detail.commonMistakes)
    }

    func testParseDetailResponseThrowsOnMalformedJSON() {
        XCTAssertThrowsError(try WordBookClient.parseDetailResponse(Data("not json".utf8))) { error in
            guard case WordBookError.decodingFailed = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        // 404 のボディが 200 で来るような想定外もデコード失敗として扱う
        XCTAssertThrowsError(
            try WordBookClient.parseDetailResponse(Data(#"{"error":"word not found"}"#.utf8)))
    }

    // MARK: - エラー文言

    func testUnauthorizedErrorMessageMentionsSecret() {
        let error = WordBookError.httpError(statusCode: 401, body: #"{"error":"unauthorized"}"#)
        XCTAssertEqual(error.errorDescription, "単語帳の認証に失敗しました（シークレットが違います）")
    }

    /// 404 は 401 / 500 と文言を混ぜない専用ケース。
    func testWordNotFoundErrorMessage() {
        XCTAssertEqual(
            WordBookError.wordNotFound.errorDescription, "単語帳にこの単語の詳細がありません")
    }
}
