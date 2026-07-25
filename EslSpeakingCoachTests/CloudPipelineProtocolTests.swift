import XCTest
@testable import EslSpeakingCoach

final class CloudPipelineProtocolTests: XCTestCase {
    // MARK: - STT（transcription セッション）のクライアントイベント

    /// session.update が GA 形式の transcription セッション（session.type = transcription、
    /// audio.input のみ）に従うことを固定する。
    func testTranscriptionSessionUpdateFollowsGAShape() throws {
        let data = try OpenAITranscriptionClientEvent.sessionUpdate(
            configuration: OpenAITranscriptionConfiguration())
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["type"] as? String, "session.update")
        let session = try XCTUnwrap(object["session"] as? [String: Any])
        XCTAssertEqual(session["type"] as? String, "transcription")

        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        // transcription セッションに output は無い
        XCTAssertNil(audio["output"])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        XCTAssertEqual((input["format"] as? [String: Any])?["type"] as? String, "audio/pcm")
        XCTAssertEqual((input["format"] as? [String: Any])?["rate"] as? Int, 24000)
        XCTAssertEqual((input["noise_reduction"] as? [String: Any])?["type"] as? String, "near_field")

        // 既定 200ms は ESL 学習者に短すぎるため明示指定する（値の意図は設定側コメント参照）
        let turnDetection = try XCTUnwrap(input["turn_detection"] as? [String: Any])
        XCTAssertEqual(turnDetection["type"] as? String, "server_vad")
        XCTAssertEqual(turnDetection["silence_duration_ms"] as? Int, 800)

        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["model"] as? String, "gpt-4o-transcribe")
        XCTAssertEqual(transcription["language"] as? String, "en")
        // 短い発話の言語誤判定対策のヒント
        XCTAssertTrue((transcription["prompt"] as? String ?? "").contains("English"))
    }

    func testTranscriptionWebsocketURLUsesTranscriptionIntent() {
        let url = OpenAITranscriptionConfiguration().websocketURL
        XCTAssertEqual(url.absoluteString, "wss://api.openai.com/v1/realtime?intent=transcription")
    }

    // MARK: - TTS のリクエスト

    /// /v1/audio/speech のボディ形式を固定する（response_format=pcm で 24kHz PCM16 が返る前提）。
    func testTTSRequestBodyShape() throws {
        let data = try OpenAITTSClient.makeRequestBody(
            configuration: OpenAITTSConfiguration(), text: "Hello there.")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["model"] as? String, "gpt-4o-mini-tts")
        XCTAssertEqual(object["voice"] as? String, "coral")
        XCTAssertEqual(object["input"] as? String, "Hello there.")
        XCTAssertEqual(object["response_format"] as? String, "pcm")
        XCTAssertFalse((object["instructions"] as? String ?? "").isEmpty)
    }

    // MARK: - Gemini TTS のリクエストと SSE パース

    /// streamGenerateContent のボディ形式を固定する（responseModalities=AUDIO + prebuilt voice。
    /// 話し方は独立フィールドが無いためテキスト先頭の自然文指示で制御する）。
    func testGeminiTTSRequestBodyShape() throws {
        let data = try GeminiTTSClient.makeRequestBody(
            configuration: GeminiTTSConfiguration(), text: "Hello there.")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let contents = try XCTUnwrap(object["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents[0]["parts"] as? [[String: Any]])
        let text = try XCTUnwrap(parts[0]["text"] as? String)
        XCTAssertTrue(text.hasSuffix("\nHello there."))
        XCTAssertTrue(text.contains("conversation coach"))

        let generationConfig = try XCTUnwrap(object["generationConfig"] as? [String: Any])
        XCTAssertEqual(generationConfig["responseModalities"] as? [String], ["AUDIO"])
        let speechConfig = try XCTUnwrap(generationConfig["speechConfig"] as? [String: Any])
        let voiceConfig = try XCTUnwrap(speechConfig["voiceConfig"] as? [String: Any])
        XCTAssertEqual(
            (voiceConfig["prebuiltVoiceConfig"] as? [String: Any])?["voiceName"] as? String, "Aoede")
    }

    func testGeminiTTSEndpointUsesModelAndKey() {
        let url = GeminiTTSConfiguration().endpoint(apiKey: "KEY123")
        XCTAssertEqual(
            url.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-tts-preview:streamGenerateContent?alt=sse&key=KEY123")
    }

    func testGeminiTTSSSEParseExtractsPCM() throws {
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        let line = #"data: {"candidates": [{"content": {"parts": [{"inlineData": {"mimeType": "audio/l16; rate=24000; channels=1","data": "\#(pcm.base64EncodedString())"}}]}}]}"#
        XCTAssertEqual(try GeminiTTSSSE.parse(line: line), pcm)
        // 音声を含まない行・SSE 以外の行は nil
        XCTAssertNil(try GeminiTTSSSE.parse(line: #"data: {"candidates": [{"content": {"parts": [{"text": "x"}]}}]}"#))
        XCTAssertNil(try GeminiTTSSSE.parse(line: ""))
    }

    func testGeminiTTSSSEParseThrowsOnError() {
        XCTAssertThrowsError(
            try GeminiTTSSSE.parse(line: #"data: {"error": {"code": 400, "message": "bad request"}}"#))
    }

    // MARK: - PCM チャンクの組み立て

    /// 最小チャンクサイズまで溜めてから吐き、常に偶数バイト（Int16 サンプル境界）で切ること。
    func testPCMChunkAssemblerBuffersUntilMinChunk() {
        var assembler = PCMChunkAssembler(minChunkBytes: 4)
        XCTAssertNil(assembler.append(0x01))
        XCTAssertNil(assembler.append(0x02))
        XCTAssertNil(assembler.append(0x03))
        XCTAssertEqual(assembler.append(0x04), Data([0x01, 0x02, 0x03, 0x04]))
        XCTAssertNil(assembler.flush())
    }

    func testPCMChunkAssemblerFlushDropsOddTailByte() {
        var assembler = PCMChunkAssembler(minChunkBytes: 100)
        for byte in [0x01, 0x02, 0x03, 0x04, 0x05] as [UInt8] {
            XCTAssertNil(assembler.append(byte))
        }
        // 終端の flush は偶数長に切り詰める（奇数の端数 0x05 は捨てる）
        XCTAssertEqual(assembler.flush(), Data([0x01, 0x02, 0x03, 0x04]))
        XCTAssertNil(assembler.flush())
    }

    func testPCMChunkAssemblerAppendsDataInBulk() {
        var assembler = PCMChunkAssembler(minChunkBytes: 4)
        XCTAssertNil(assembler.append(contentsOf: Data([0x01, 0x02])))
        XCTAssertEqual(
            assembler.append(contentsOf: Data([0x03, 0x04, 0x05])),
            Data([0x01, 0x02, 0x03, 0x04]))
        XCTAssertEqual(assembler.flush(), nil)
        XCTAssertEqual(assembler.append(contentsOf: Data([0x06, 0x07, 0x08])), Data([0x05, 0x06, 0x07, 0x08]))
    }

    func testPCMChunkAssemblerKeepsOddByteForNextChunk() {
        var assembler = PCMChunkAssembler(minChunkBytes: 3)
        XCTAssertNil(assembler.append(0x01))
        XCTAssertNil(assembler.append(0x02))
        // 3 バイト目で minChunk に達するが、偶数境界の 2 バイトだけ吐いて 1 バイト残す
        XCTAssertEqual(assembler.append(0x03), Data([0x01, 0x02]))
        XCTAssertNil(assembler.append(0x04))
        XCTAssertEqual(assembler.flush(), Data([0x03, 0x04]))
    }
}
