import XCTest
@testable import EslSpeakingCoach

/// 単語登録まわりの API クライアント（正規化・登録の POST 2 本）のテスト
/// （docs/plans/tap-word-registration.md Phase 1）。
final class WordRegistrationClientTests: XCTestCase {
    /// リクエストボディの検証用（JSON のキー順に依存しないようデコードして比べる）
    private struct Body: Decodable, Equatable {
        let word: String
        let targetLanguage: String
        let context: String?
    }

    // MARK: - makeNormalizeRequest / makeRegisterRequest

    func testMakeNormalizeRequestBuildsURLHeaderAndBody() throws {
        let request = WordBookClient.makeNormalizeRequest(
            secret: "test-secret_1234567890", word: "picked",
            context: "I picked it up yesterday.")
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.absoluteString, "https://esl.chobi.me/api/word-normalize")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Secret"), "test-secret_1234567890")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try JSONDecoder().decode(Body.self, from: XCTUnwrap(request.httpBody))
        XCTAssertEqual(
            body,
            Body(word: "picked", targetLanguage: "ja", context: "I picked it up yesterday."))
    }

    func testMakeRegisterRequestBuildsURLAndBody() throws {
        let request = WordBookClient.makeRegisterRequest(
            secret: "s", word: "get around to", context: "I finally got around to it.")
        XCTAssertEqual(request.url?.absoluteString, "https://esl.chobi.me/api/word-info")
        XCTAssertEqual(request.httpMethod, "POST")

        let body = try JSONDecoder().decode(Body.self, from: XCTUnwrap(request.httpBody))
        // 熟語のスペースは JSON ボディなのでそのまま載る
        XCTAssertEqual(body.word, "get around to")
        XCTAssertEqual(body.targetLanguage, "ja")
    }

    /// context なし（nil）のとき JSON からキーごと落ちる（サーバは undefined 扱い）。
    func testMakePostRequestOmitsNilContext() throws {
        let request = WordBookClient.makeNormalizeRequest(secret: "s", word: "run", context: nil)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertNil(json["context"])
        XCTAssertEqual(json["word"] as? String, "run")
    }

    // MARK: - parseNormalization

    func testParseNormalizationPhrasePart() throws {
        let json = """
        {"input": "up", "lemma": "look up", "status": "phrase_part",
         "reason": "文中の『up』は句動詞『look up』の一部です", "cached": false}
        """
        let result = try WordBookClient.parseNormalization(Data(json.utf8))
        XCTAssertEqual(result.input, "up")
        XCTAssertEqual(result.lemma, "look up")
        XCTAssertEqual(result.status, .phrasePart)
        XCTAssertEqual(result.reason, "文中の『up』は句動詞『look up』の一部です")
        XCTAssertFalse(result.cached)
    }

    func testParseNormalizationCanonicalWithEmptyReason() throws {
        let json = """
        {"input": "run", "lemma": "run", "status": "canonical", "reason": "", "cached": true}
        """
        let result = try WordBookClient.parseNormalization(Data(json.utf8))
        XCTAssertEqual(result.status, .canonical)
        XCTAssertEqual(result.reason, "")
        XCTAssertTrue(result.cached)
    }

    /// サーバ側で status の分類が増えても unknown（提案なし扱い）に畳んで壊れない。
    func testParseNormalizationUnknownStatusFallsBack() throws {
        let json = """
        {"input": "x", "lemma": "x", "status": "brand_new_status", "reason": "", "cached": false}
        """
        let result = try WordBookClient.parseNormalization(Data(json.utf8))
        XCTAssertEqual(result.status, .unknown)
    }

    func testParseNormalizationBrokenJSONThrows() {
        XCTAssertThrowsError(
            try WordBookClient.parseNormalization(Data("{\"input\": 1}".utf8))
        ) { error in
            guard case WordBookError.decodingFailed = error else {
                return XCTFail("decodingFailed であるべき: \(error)")
            }
        }
    }

    // MARK: - parseRegistration

    func testParseRegistrationNewWord() throws {
        let json = """
        {"wordInfo": {"senses": [{"meaning": "〜する時間を見つける", "partOfSpeech": "句動詞"}],
         "examples": []}, "model": "claude-haiku-4-5", "cached": false}
        """
        let result = try WordBookClient.parseRegistration(Data(json.utf8))
        XCTAssertFalse(result.cached)
        XCTAssertEqual(result.firstMeaning, "〜する時間を見つける")
    }

    func testParseRegistrationCachedWord() throws {
        let json = """
        {"wordInfo": {"senses": [{"meaning": "走る"}]}, "model": "m", "cached": true}
        """
        let result = try WordBookClient.parseRegistration(Data(json.utf8))
        XCTAssertTrue(result.cached)
        XCTAssertEqual(result.firstMeaning, "走る")
    }

    /// senses が欠けた応答でも登録成否は返す（firstMeaning は nil で表示側が畳む）。
    func testParseRegistrationWithoutSenses() throws {
        let json = """
        {"wordInfo": {}, "model": "m", "cached": false}
        """
        let result = try WordBookClient.parseRegistration(Data(json.utf8))
        XCTAssertFalse(result.cached)
        XCTAssertNil(result.firstMeaning)
    }

    func testParseRegistrationBrokenJSONThrows() {
        XCTAssertThrowsError(
            try WordBookClient.parseRegistration(Data("not json".utf8))
        ) { error in
            guard case WordBookError.decodingFailed = error else {
                return XCTFail("decodingFailed であるべき: \(error)")
            }
        }
    }
}
