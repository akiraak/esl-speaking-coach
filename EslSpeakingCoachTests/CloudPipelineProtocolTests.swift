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

    func testTranscriptionInputAudioAppend() throws {
        let data = try OpenAITranscriptionClientEvent.inputAudioAppend(base64Audio: "QUJD")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "input_audio_buffer.append")
        XCTAssertEqual(object["audio"] as? String, "QUJD")
    }

    // MARK: - STT の prompt エコー幻覚フィルタ

    private let sttPrompt = OpenAITranscriptionConfiguration().prompt

    /// 非発話セグメントで prompt がそのままエコーされるケース（句読点・大文字小文字の揺れ込み）
    func testPromptEchoDetectsFullEcho() {
        XCTAssertTrue(STTHallucinationFilter.isPromptEcho(transcript: sttPrompt, prompt: sttPrompt))
        // 実機で観測された形: 末尾ピリオドなし・改行継ぎ目の揺れ
        XCTAssertTrue(STTHallucinationFilter.isPromptEcho(
            transcript: "The speaker is a Japanese adult practicing English conversation. "
                + "The audio is always English",
            prompt: sttPrompt))
        XCTAssertTrue(STTHallucinationFilter.isPromptEcho(
            transcript: "the speaker is a japanese adult practicing english conversation, "
                + "the audio is always english.",
            prompt: sttPrompt))
    }

    /// 末尾が切れたエコー（prompt の先頭部分だけ）も破棄する
    func testPromptEchoDetectsTruncatedEcho() {
        XCTAssertTrue(STTHallucinationFilter.isPromptEcho(
            transcript: "The speaker is a Japanese adult practicing", prompt: sttPrompt))
    }

    /// prompt が 2 回以上繰り返されるエコー（+ 末尾の切れ端）も破棄する
    func testPromptEchoDetectsRepeatedEcho() {
        let full = "The speaker is a Japanese adult practicing English conversation. "
            + "The audio is always English."
        XCTAssertTrue(STTHallucinationFilter.isPromptEcho(
            transcript: full + " " + full, prompt: sttPrompt))
        XCTAssertTrue(STTHallucinationFilter.isPromptEcho(
            transcript: full + " The speaker is a Japanese", prompt: sttPrompt))
    }

    /// 正当な発話は prompt と単語が重なっても破棄しない
    func testPromptEchoKeepsLegitimateUtterances() {
        // prompt の途中とだけ一致（先頭一致でない）
        XCTAssertFalse(STTHallucinationFilter.isPromptEcho(
            transcript: "I'm practicing English conversation.", prompt: sttPrompt))
        XCTAssertFalse(STTHallucinationFilter.isPromptEcho(
            transcript: "English conversation is fun.", prompt: sttPrompt))
        // 短い発話は先頭が偶然一致しても通す（最小長ガード）
        XCTAssertFalse(STTHallucinationFilter.isPromptEcho(
            transcript: "The speaker", prompt: sttPrompt))
        XCTAssertFalse(STTHallucinationFilter.isPromptEcho(
            transcript: "Hello!", prompt: sttPrompt))
        XCTAssertFalse(STTHallucinationFilter.isPromptEcho(transcript: "", prompt: sttPrompt))
    }

    // MARK: - STT のサーバイベントのパース

    func testTranscriptionParseLifecycleEvents() {
        XCTAssertEqual(
            OpenAITranscriptionServerEvent.parse(#"{"type":"session.created"}"#), .sessionCreated)
        XCTAssertEqual(
            OpenAITranscriptionServerEvent.parse(#"{"type":"session.updated"}"#), .sessionUpdated)
        XCTAssertEqual(
            OpenAITranscriptionServerEvent.parse(#"{"type":"input_audio_buffer.speech_started"}"#),
            .speechStarted)
        XCTAssertEqual(
            OpenAITranscriptionServerEvent.parse(#"{"type":"input_audio_buffer.speech_stopped"}"#),
            .speechStopped)
    }

    func testTranscriptionParseTranscripts() {
        XCTAssertEqual(
            OpenAITranscriptionServerEvent.parse(
                #"{"type":"conversation.item.input_audio_transcription.delta","delta":"Hel"}"#),
            .userTranscriptDelta("Hel"))
        XCTAssertEqual(
            OpenAITranscriptionServerEvent.parse(
                #"{"type":"conversation.item.input_audio_transcription.completed","transcript":"Hello"}"#),
            .userTranscriptCompleted("Hello", usage: nil))
        XCTAssertEqual(
            OpenAITranscriptionServerEvent.parse(
                #"{"type":"conversation.item.input_audio_transcription.failed","error":{"type":"transcription_error","message":"audio too noisy"}}"#),
            .userTranscriptFailed("audio too noisy"))
    }

    /// gpt-4o-transcribe の completed はトークン型 usage を持つ（料金記録用にパースする）。
    func testTranscriptionParseTokenUsage() {
        let event = OpenAITranscriptionServerEvent.parse(#"""
            {"type":"conversation.item.input_audio_transcription.completed","transcript":"Hello",
             "usage":{"type":"tokens","total_tokens":25,"input_tokens":20,
                      "input_token_details":{"text_tokens":2,"audio_tokens":18},"output_tokens":5}}
            """#)
        XCTAssertEqual(event, .userTranscriptCompleted(
            "Hello",
            usage: STTSegmentUsage(audioInputTokens: 18, textInputTokens: 2, outputTokens: 5)))
    }

    /// whisper 系は秒数型 usage で届く。
    func testTranscriptionParseDurationUsage() {
        let event = OpenAITranscriptionServerEvent.parse(#"""
            {"type":"conversation.item.input_audio_transcription.completed","transcript":"Hi",
             "usage":{"type":"duration","seconds":3.5}}
            """#)
        XCTAssertEqual(event, .userTranscriptCompleted(
            "Hi", usage: STTSegmentUsage(audioSeconds: 3.5)))
    }

    func testTranscriptionParseError() {
        XCTAssertEqual(
            OpenAITranscriptionServerEvent.parse(
                #"{"type":"error","error":{"code":"rate_limit","message":"slow down"}}"#),
            .serverError(message: "slow down", ignorable: false))
        XCTAssertEqual(
            OpenAITranscriptionServerEvent.parse(
                #"{"type":"error","error":{"code":"response_cancel_not_active","message":"Cancellation failed"}}"#),
            .serverError(message: "Cancellation failed", ignorable: true))
    }

    func testTranscriptionParseUnknownTypeIsIgnored() {
        XCTAssertEqual(
            OpenAITranscriptionServerEvent.parse(#"{"type":"rate_limits.updated"}"#),
            .ignored(type: "rate_limits.updated"))
        XCTAssertEqual(
            OpenAITranscriptionServerEvent.parse("not json"), .ignored(type: "(unparsable)"))
    }

    // MARK: - TTS のリクエスト

    /// /v1/audio/speech のボディ形式を固定する（response_format=pcm で 24kHz PCM16 が返る前提）。
    /// OpenAI は voice 体系が異なるため SpeechStyle.voice ではなく設定の固定 voice を使う。
    func testTTSRequestBodyShape() throws {
        let data = try OpenAITTSClient.makeRequestBody(
            configuration: OpenAITTSConfiguration(), text: "Hello there.",
            style: ChatCharacter.chobi.speechStyle)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["model"] as? String, "gpt-4o-mini-tts")
        XCTAssertEqual(object["voice"] as? String, "coral")
        XCTAssertEqual(object["input"] as? String, "Hello there.")
        XCTAssertEqual(object["response_format"] as? String, "pcm")
        XCTAssertEqual(
            object["instructions"] as? String, ChatCharacter.chobi.speechStyle.styleInstruction)
    }

    // MARK: - Gemini TTS のリクエストと SSE パース

    /// streamGenerateContent のボディ形式を固定する（responseModalities=AUDIO + prebuilt voice。
    /// 話し方は独立フィールドが無いためテキスト先頭の自然文指示で制御する）。
    /// voice / スタイル前置文は発話ごとの SpeechStyle（キャラ）で切り替わること。
    func testGeminiTTSRequestBodyShape() throws {
        for (character, expectedVoice) in [(ChatCharacter.chobi, "Leda"), (.naruko, "Aoede")] {
            let data = try GeminiTTSClient.makeRequestBody(
                configuration: GeminiTTSConfiguration(), text: "Hello there.",
                style: character.speechStyle)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

            let contents = try XCTUnwrap(object["contents"] as? [[String: Any]])
            let parts = try XCTUnwrap(contents[0]["parts"] as? [[String: Any]])
            let text = try XCTUnwrap(parts[0]["text"] as? String)
            XCTAssertTrue(text.hasSuffix("\nHello there."))
            XCTAssertTrue(text.hasPrefix(character.speechStyle.styleInstruction))

            let generationConfig = try XCTUnwrap(object["generationConfig"] as? [String: Any])
            XCTAssertEqual(generationConfig["responseModalities"] as? [String], ["AUDIO"])
            let speechConfig = try XCTUnwrap(generationConfig["speechConfig"] as? [String: Any])
            let voiceConfig = try XCTUnwrap(speechConfig["voiceConfig"] as? [String: Any])
            XCTAssertEqual(
                (voiceConfig["prebuiltVoiceConfig"] as? [String: Any])?["voiceName"] as? String,
                expectedVoice)
        }
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
        XCTAssertEqual(try GeminiTTSSSE.parse(line: line), GeminiTTSSSE.Parsed(pcm: pcm))
        // 音声も usage も含まない行・SSE 以外の行は nil
        XCTAssertNil(try GeminiTTSSSE.parse(line: #"data: {"candidates": [{"content": {"parts": [{"text": "x"}]}}]}"#))
        XCTAssertNil(try GeminiTTSSSE.parse(line: ""))
    }

    /// usageMetadata を含むチャンクからトークン数を取り出す（料金記録用）。
    /// candidatesTokenCount（TTS では音声出力）を採用し、無ければ total - prompt で補う。
    func testGeminiTTSSSEParseExtractsUsageMetadata() throws {
        let line = #"data: {"usageMetadata": {"promptTokenCount": 30, "candidatesTokenCount": 150, "totalTokenCount": 180}}"#
        let parsed = try XCTUnwrap(GeminiTTSSSE.parse(line: line))
        XCTAssertNil(parsed.pcm)
        XCTAssertEqual(parsed.usage?.promptTokenCount, 30)
        XCTAssertEqual(parsed.usage?.audioOutputTokens, 150)

        let withoutCandidates = #"data: {"usageMetadata": {"promptTokenCount": 30, "totalTokenCount": 180}}"#
        XCTAssertEqual(try GeminiTTSSSE.parse(line: withoutCandidates)?.usage?.audioOutputTokens, 150)
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
