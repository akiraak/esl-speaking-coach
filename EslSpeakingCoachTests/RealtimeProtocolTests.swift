import XCTest
@testable import EslSpeakingCoach

final class RealtimeProtocolTests: XCTestCase {
    // MARK: - クライアントイベントの生成

    /// session.update が GA 形式（session.audio.input / output のネスト構造）に従うことを固定する。
    func testSessionUpdateFollowsGAShape() throws {
        let data = try RealtimeClientEvent.sessionUpdate(configuration: RealtimeConfiguration())
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["type"] as? String, "session.update")
        let session = try XCTUnwrap(object["session"] as? [String: Any])
        XCTAssertEqual(session["type"] as? String, "realtime")
        XCTAssertEqual(session["output_modalities"] as? [String], ["audio"])
        // model は URL クエリで指定するため session.update には含めない
        XCTAssertNil(session["model"])
        XCTAssertFalse((session["instructions"] as? String ?? "").isEmpty)

        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        XCTAssertEqual((input["format"] as? [String: Any])?["type"] as? String, "audio/pcm")
        XCTAssertEqual((input["format"] as? [String: Any])?["rate"] as? Int, 24000)
        XCTAssertEqual((input["turn_detection"] as? [String: Any])?["type"] as? String, "server_vad")
        XCTAssertEqual((input["transcription"] as? [String: Any])?["model"] as? String, "gpt-4o-transcribe")

        let output = try XCTUnwrap(audio["output"] as? [String: Any])
        XCTAssertEqual((output["format"] as? [String: Any])?["rate"] as? Int, 24000)
        XCTAssertEqual(output["voice"] as? String, "marin")
    }

    func testWebsocketURLContainsModel() {
        let url = RealtimeConfiguration().websocketURL
        XCTAssertEqual(url.absoluteString, "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini")
    }

    func testInputAudioAppend() throws {
        let data = try RealtimeClientEvent.inputAudioAppend(base64Audio: "QUJD")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "input_audio_buffer.append")
        XCTAssertEqual(object["audio"] as? String, "QUJD")
    }

    func testUserTextItem() throws {
        let data = try RealtimeClientEvent.userTextItem("Hello coach")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "conversation.item.create")
        let item = try XCTUnwrap(object["item"] as? [String: Any])
        XCTAssertEqual(item["type"] as? String, "message")
        XCTAssertEqual(item["role"] as? String, "user")
        let content = try XCTUnwrap(item["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content[0]["type"] as? String, "input_text")
        XCTAssertEqual(content[0]["text"] as? String, "Hello coach")
    }

    // MARK: - サーバイベントのパース

    func testParseLifecycleEvents() {
        XCTAssertEqual(RealtimeServerEvent.parse(#"{"type":"session.created"}"#), .sessionCreated)
        XCTAssertEqual(RealtimeServerEvent.parse(#"{"type":"session.updated"}"#), .sessionUpdated)
        XCTAssertEqual(
            RealtimeServerEvent.parse(#"{"type":"input_audio_buffer.speech_started"}"#), .speechStarted)
        XCTAssertEqual(
            RealtimeServerEvent.parse(#"{"type":"input_audio_buffer.speech_stopped"}"#), .speechStopped)
        XCTAssertEqual(RealtimeServerEvent.parse(#"{"type":"response.created"}"#), .responseCreated)
        XCTAssertEqual(RealtimeServerEvent.parse(#"{"type":"response.done"}"#), .responseDone)
    }

    func testParseAudioDeltaDecodesBase64() {
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        let json = #"{"type":"response.output_audio.delta","delta":"\#(pcm.base64EncodedString())"}"#
        XCTAssertEqual(RealtimeServerEvent.parse(json), .assistantAudioDelta(pcm))
    }

    func testParseTranscripts() {
        XCTAssertEqual(
            RealtimeServerEvent.parse(
                #"{"type":"conversation.item.input_audio_transcription.delta","delta":"Hel"}"#),
            .userTranscriptDelta("Hel"))
        XCTAssertEqual(
            RealtimeServerEvent.parse(
                #"{"type":"conversation.item.input_audio_transcription.completed","transcript":"Hello"}"#),
            .userTranscriptCompleted("Hello"))
        XCTAssertEqual(
            RealtimeServerEvent.parse(
                #"{"type":"conversation.item.input_audio_transcription.failed","error":{"type":"transcription_error","message":"audio too noisy"}}"#),
            .userTranscriptFailed("audio too noisy"))
        XCTAssertEqual(
            RealtimeServerEvent.parse(
                #"{"type":"response.output_audio_transcript.delta","delta":"Hi "}"#),
            .assistantTranscriptDelta("Hi "))
        XCTAssertEqual(
            RealtimeServerEvent.parse(
                #"{"type":"response.output_audio_transcript.done","transcript":"Hi there."}"#),
            .assistantTranscriptDone("Hi there."))
    }

    func testParseError() {
        XCTAssertEqual(
            RealtimeServerEvent.parse(
                #"{"type":"error","error":{"code":"rate_limit","message":"slow down"}}"#),
            .serverError(message: "slow down", ignorable: false))
        // 応答終了後の response.cancel 競合は無害として扱う
        XCTAssertEqual(
            RealtimeServerEvent.parse(
                #"{"type":"error","error":{"code":"response_cancel_not_active","message":"Cancellation failed"}}"#),
            .serverError(message: "Cancellation failed", ignorable: true))
    }

    func testParseUnknownTypeIsIgnored() {
        XCTAssertEqual(
            RealtimeServerEvent.parse(#"{"type":"rate_limits.updated"}"#),
            .ignored(type: "rate_limits.updated"))
        XCTAssertEqual(RealtimeServerEvent.parse("not json"), .ignored(type: "(unparsable)"))
    }
}
