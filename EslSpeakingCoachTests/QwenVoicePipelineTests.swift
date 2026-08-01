import XCTest
@testable import EslSpeakingCoach

/// Alibaba Qwen 音声モデル（検証用切替経路。docs/plans/alibaba-voice-models.md）の
/// プロトコル層のテスト。イベント JSON の形は 2026-08-01 の実測（scratchpad phase1）で固定。
final class QwenVoicePipelineTests: XCTestCase {
    // MARK: - STT モデル選択

    /// -stt-model qwen3-asr-flash-realtime で Qwen 経路（クライアント VAD + 16kHz）に切り替わる。
    /// 既定（gpt-live-transcribe）の挙動は変えない
    func testSTTModelSelectionFlags() {
        var configuration = OpenAITranscriptionConfiguration()
        XCTAssertFalse(configuration.isQwenASR)
        XCTAssertTrue(configuration.usesClientEndpointing)
        XCTAssertEqual(configuration.micSampleRate, 24000)

        configuration.model = "qwen3-asr-flash-realtime"
        XCTAssertTrue(configuration.isQwenASR)
        XCTAssertTrue(configuration.usesClientEndpointing)
        XCTAssertEqual(configuration.micSampleRate, 16000)

        configuration.model = "gpt-4o-transcribe"
        XCTAssertFalse(configuration.usesClientEndpointing)
        XCTAssertEqual(configuration.micSampleRate, 24000)
    }

    // MARK: - Qwen ASR クライアントイベント

    /// session.update は manual mode（turn_detection: null）+ pcm 16kHz + 言語固定。
    /// event_id は必須（Qwen 仕様）
    func testQwenSessionUpdateShape() throws {
        let data = try QwenTranscriptionClientEvent.sessionUpdate(
            configuration: QwenTranscriptionConfiguration())
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["type"] as? String, "session.update")
        XCTAssertNotNil(object["event_id"])
        let session = try XCTUnwrap(object["session"] as? [String: Any])
        XCTAssertEqual(session["input_audio_format"] as? String, "pcm")
        XCTAssertEqual(session["sample_rate"] as? Int, 16000)
        XCTAssertTrue(session["turn_detection"] is NSNull)
        let transcription = try XCTUnwrap(session["input_audio_transcription"] as? [String: Any])
        XCTAssertEqual(transcription["language"] as? String, "en")
    }

    // MARK: - Qwen ASR サーバイベント

    /// partial は text（確定 prefix）+ stash（未確定の続き）の連結を累積テキストとして流す
    func testQwenPartialConcatenatesTextAndStash() {
        let event = QwenTranscriptionServerEvent.parse(
            #"{"type":"conversation.item.input_audio_transcription.text","text":"Last weekend ","stash":"I go","language":"en"}"#)
        XCTAssertEqual(event, .partial("Last weekend I go"))
    }

    /// completed の usage は duration（秒）とトークン内訳の両建て。
    /// 課金は秒数ベースなので audioSeconds に必ず入ること
    func testQwenCompletedParsesUsage() {
        let event = QwenTranscriptionServerEvent.parse(#"""
            {"type":"conversation.item.input_audio_transcription.completed",
             "transcript":"Hello there.",
             "usage":{"duration":7,"total_tokens":153,"input_tokens":111,"output_tokens":42,
                      "input_tokens_details":{"text_tokens":3,"audio_tokens":108}}}
            """#)
        guard case .completed(let transcript, let usage) = event else {
            return XCTFail("completed ではない: \(event)")
        }
        XCTAssertEqual(transcript, "Hello there.")
        XCTAssertEqual(usage?.audioSeconds, 7)
        XCTAssertEqual(usage?.audioInputTokens, 108)
        XCTAssertEqual(usage?.outputTokens, 42)
    }

    /// バッファ操作系のエラーは ignorable（セッションを殺さない）。
    /// clear 非対応の invalid_value（param=type）は ignorable ではない扱いでよい
    /// （実装は clear を送らず commit + 読み捨てで代替している）
    func testQwenErrorClassification() {
        let bufferError = QwenTranscriptionServerEvent.parse(
            #"{"type":"error","error":{"code":"input_audio_buffer_commit_empty","message":"buffer is empty"}}"#)
        guard case .serverError(_, let ignorable) = bufferError else {
            return XCTFail("serverError ではない")
        }
        XCTAssertTrue(ignorable)

        let fatalError = QwenTranscriptionServerEvent.parse(
            #"{"type":"error","error":{"code":"invalid_api_key","message":"invalid api key"}}"#)
        guard case .serverError(_, let fatalIgnorable) = fatalError else {
            return XCTFail("serverError ではない")
        }
        XCTAssertFalse(fatalIgnorable)
    }

    // MARK: - Qwen TTS

    /// SpeechStyle.voice（Gemini の voice 名）→ Qwen voice 名の写像。
    /// 既定は実聴選定の Chobi=Serena / Naruko=Vivian。未知の voice は defaultVoice に倒す
    func testQwenTTSVoiceMapping() {
        let configuration = QwenTTSConfiguration()
        XCTAssertEqual(
            configuration.voice(for: ChatCharacter.chobi.speechStyle), "Serena")
        XCTAssertEqual(
            configuration.voice(for: ChatCharacter.naruko.speechStyle), "Vivian")
        XCTAssertEqual(
            configuration.voice(for: SpeechStyle(voice: "Unknown", styleInstruction: "")),
            configuration.defaultVoice)
    }

    /// スタイル指示は instruct 変種のときだけ返る（base モデルは非対応なので必ず nil）。
    /// 指示はキャラごと（Gemini voice 名キー）に持ち、未知の voice は指示なし
    func testQwenTTSInstructions() {
        var configuration = QwenTTSConfiguration()
        XCTAssertNil(configuration.instructions(for: ChatCharacter.chobi.speechStyle))

        configuration.model = QwenTTSConfiguration.instructModel
        let chobi = configuration.instructions(for: ChatCharacter.chobi.speechStyle)
        let naruko = configuration.instructions(for: ChatCharacter.naruko.speechStyle)
        XCTAssertTrue(chobi?.contains("casual") == true)
        XCTAssertTrue(naruko?.contains("enthusiastic student") == true)
        XCTAssertNotEqual(chobi, naruko)
        XCTAssertNil(
            configuration.instructions(for: SpeechStyle(voice: "Unknown", styleInstruction: "")))
    }

    // MARK: - 料金（alibaba プロバイダ）

    /// STT は $0.000090 / 秒の秒数課金
    func testQwenASRPricing() {
        let event = AIUsageEvent(
            provider: .alibaba, model: "qwen3-asr-flash-realtime", kind: .speechToText,
            audioSeconds: 100)
        XCTAssertEqual(AIPricing.estimatedCostUSD(for: event), 0.009, accuracy: 1e-9)
    }

    /// TTS は $0.13 / 1 万文字（inputTokens に課金文字数が入る）。
    /// 文字数が無いときは音声秒数からの概算に落ちる
    func testQwenTTSPricing() {
        let byCharacters = AIUsageEvent(
            provider: .alibaba, model: "qwen3-tts-flash-realtime", kind: .textToSpeech,
            inputTokens: 10_000, audioSeconds: 60)
        XCTAssertEqual(AIPricing.estimatedCostUSD(for: byCharacters), 0.13, accuracy: 1e-9)

        let bySeconds = AIUsageEvent(
            provider: .alibaba, model: "qwen3-tts-flash-realtime", kind: .textToSpeech,
            audioSeconds: 60)
        XCTAssertEqual(AIPricing.estimatedCostUSD(for: bySeconds), 0.0098, accuracy: 1e-9)
    }
}
