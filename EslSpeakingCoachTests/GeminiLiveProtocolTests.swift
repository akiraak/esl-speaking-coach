import XCTest
@testable import EslSpeakingCoach

final class GeminiLiveProtocolTests: XCTestCase {
    // MARK: - クライアントメッセージの生成

    /// setup が Live API の形式（models/ プレフィックス・generationConfig・transcript 有効化）に従うことを固定する。
    func testSetupShape() throws {
        let data = try GeminiLiveClientEvent.setup(configuration: GeminiLiveConfiguration())
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let setup = try XCTUnwrap(object["setup"] as? [String: Any])
        XCTAssertEqual(setup["model"] as? String, "models/gemini-3.1-flash-live-preview")

        let generationConfig = try XCTUnwrap(setup["generationConfig"] as? [String: Any])
        XCTAssertEqual(generationConfig["responseModalities"] as? [String], ["AUDIO"])
        let speechConfig = try XCTUnwrap(generationConfig["speechConfig"] as? [String: Any])
        let voiceConfig = try XCTUnwrap(speechConfig["voiceConfig"] as? [String: Any])
        XCTAssertEqual(
            (voiceConfig["prebuiltVoiceConfig"] as? [String: Any])?["voiceName"] as? String, "Aoede")

        let systemInstruction = try XCTUnwrap(setup["systemInstruction"] as? [String: Any])
        let parts = try XCTUnwrap(systemInstruction["parts"] as? [[String: Any]])
        XCTAssertFalse((parts.first?["text"] as? String ?? "").isEmpty)

        // 評価フェーズ用に入出力とも transcript を有効化していること
        XCTAssertNotNil(setup["inputAudioTranscription"])
        XCTAssertNotNil(setup["outputAudioTranscription"])
    }

    func testWebsocketURLEncodesKey() throws {
        let url = try XCTUnwrap(GeminiLiveConfiguration().websocketURL(apiKey: "test-key"))
        XCTAssertEqual(
            url.absoluteString,
            "wss://generativelanguage.googleapis.com/ws/"
                + "google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=test-key")
    }

    func testAudioChunkUses16kPCM() throws {
        let data = try GeminiLiveClientEvent.audioChunk(base64Audio: "QUJD")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let realtimeInput = try XCTUnwrap(object["realtimeInput"] as? [String: Any])
        let audio = try XCTUnwrap(realtimeInput["audio"] as? [String: Any])
        XCTAssertEqual(audio["data"] as? String, "QUJD")
        XCTAssertEqual(audio["mimeType"] as? String, "audio/pcm;rate=16000")
    }

    func testUserTextTurn() throws {
        let data = try GeminiLiveClientEvent.userTextTurn("Hello coach")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let clientContent = try XCTUnwrap(object["clientContent"] as? [String: Any])
        XCTAssertEqual(clientContent["turnComplete"] as? Bool, true)
        let turns = try XCTUnwrap(clientContent["turns"] as? [[String: Any]])
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0]["role"] as? String, "user")
        let parts = try XCTUnwrap(turns[0]["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.first?["text"] as? String, "Hello coach")
    }

    // MARK: - サーバメッセージのパース

    func testParseSetupComplete() {
        XCTAssertEqual(GeminiLiveServerEvent.parse(#"{"setupComplete":{}}"#), [.setupComplete])
    }

    func testParseAudioDeltaDecodesBase64() {
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        let json = """
            {"serverContent":{"modelTurn":{"parts":[\
            {"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"\(pcm.base64EncodedString())"}}]}}}
            """
        XCTAssertEqual(GeminiLiveServerEvent.parse(json), [.assistantAudioDelta(pcm)])
    }

    func testParseTranscriptions() {
        XCTAssertEqual(
            GeminiLiveServerEvent.parse(#"{"serverContent":{"inputTranscription":{"text":"Hel"}}}"#),
            [.userTranscriptDelta("Hel")])
        XCTAssertEqual(
            GeminiLiveServerEvent.parse(#"{"serverContent":{"outputTranscription":{"text":"Hi "}}}"#),
            [.assistantTranscriptDelta("Hi ")])
    }

    /// serverContent には複数のサブイベントが同居し得る。
    /// transcript → 音声 → interrupted → turnComplete の順に返すこと（この順で処理すれば安全）。
    func testParseCombinedServerContentKeepsSafeOrder() {
        let pcm = Data([0x0A, 0x0B])
        let json = """
            {"serverContent":{"turnComplete":true,"interrupted":true,\
            "outputTranscription":{"text":"bye"},\
            "modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm","data":"\(pcm.base64EncodedString())"}}]}}}
            """
        XCTAssertEqual(
            GeminiLiveServerEvent.parse(json),
            [.assistantTranscriptDelta("bye"), .assistantAudioDelta(pcm), .interrupted, .turnComplete])
    }

    func testParseTurnLifecycle() {
        XCTAssertEqual(
            GeminiLiveServerEvent.parse(#"{"serverContent":{"generationComplete":true}}"#),
            [.generationComplete])
        XCTAssertEqual(
            GeminiLiveServerEvent.parse(#"{"serverContent":{"turnComplete":true}}"#),
            [.turnComplete])
        XCTAssertEqual(
            GeminiLiveServerEvent.parse(#"{"serverContent":{"interrupted":true}}"#),
            [.interrupted])
    }

    func testParseGoAway() {
        XCTAssertEqual(
            GeminiLiveServerEvent.parse(#"{"goAway":{"timeLeft":"30s"}}"#),
            [.goAway(timeLeft: "30s")])
    }

    func testParseUnknownIsIgnored() {
        XCTAssertEqual(
            GeminiLiveServerEvent.parse(#"{"usageMetadata":{"totalTokenCount":10}}"#),
            [.ignored(field: "usageMetadata")])
        XCTAssertEqual(GeminiLiveServerEvent.parse("not json"), [.ignored(field: "(unparsable)")])
    }
}
