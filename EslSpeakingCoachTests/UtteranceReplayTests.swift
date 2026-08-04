import XCTest
@testable import EslSpeakingCoach

/// チャット欄英語の再読み上げ（docs/plans/utterance-replay.md）のテスト。
/// TTS クライアント生成のファクトリ分岐・音声キャッシュ（WAV 読み書き・.part 完結遷移・掃除）を見る。
final class UtteranceReplayTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("UtteranceReplayTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - ファクトリのプロバイダ分岐

    /// セッションと再読み上げが共有する生成分岐。既定は Gemini Flash TTS
    /// （2026-08-03 に Qwen instruct から戻した）。
    func testFactoryDefaultsToGemini() {
        let configuration = SentenceTTSClientFactory.Configuration()
        XCTAssertEqual(configuration.provider, .gemini)
        let client = SentenceTTSClientFactory.make(configuration)
        XCTAssertEqual(client.modelDescription, GeminiTTSConfiguration().model)
    }

    /// Gemini は ChatCharacter.speechStyle の voice / スタイル前置文をそのまま使う
    /// （Qwen だけが voiceMap / instructionMap で写像していた）。
    func testGeminiUsesCharacterSpeechStyleDirectly() {
        XCTAssertEqual(ChatCharacter.chobi.speechStyle.voice, "Leda")
        XCTAssertEqual(ChatCharacter.naruko.speechStyle.voice, "Aoede")
        for character in ChatCharacter.allCases {
            XCTAssertFalse(
                character.speechStyle.styleInstruction.isEmpty,
                "\(character.displayName) のスタイル前置文が空")
        }
    }

    func testFactoryProviderBranches() {
        var configuration = SentenceTTSClientFactory.Configuration()
        configuration.provider = .openAI
        XCTAssertTrue(SentenceTTSClientFactory.make(configuration) is OpenAITTSClient)
        configuration.provider = .gemini
        XCTAssertTrue(SentenceTTSClientFactory.make(configuration) is GeminiTTSClient)
        configuration.provider = .qwen
        XCTAssertTrue(SentenceTTSClientFactory.make(configuration) is QwenTTSClient)
    }

    // MARK: - WAV 読み書き

    func testWAVHeaderRoundTrip() {
        let payload = Data((0..<4800).map { UInt8($0 % 251) })
        var file = UtteranceAudioCache.wavHeader(dataSize: payload.count)
        file.append(payload)
        XCTAssertEqual(UtteranceAudioCache.wavPCMPayload(file), payload)
    }

    /// サイズ不整合（書きかけ相当）や別形式のデータは鳴らさない。
    func testWAVPayloadRejectsBrokenData() {
        let payload = Data(repeating: 0x42, count: 100)
        var truncated = UtteranceAudioCache.wavHeader(dataSize: payload.count)
        truncated.append(payload.prefix(50))
        XCTAssertNil(UtteranceAudioCache.wavPCMPayload(truncated))
        XCTAssertNil(UtteranceAudioCache.wavPCMPayload(Data(repeating: 0, count: 200)))
        XCTAssertNil(UtteranceAudioCache.wavPCMPayload(Data()))
    }

    // MARK: - recorder の完結・未完遷移

    private func makeRecorder(sessionID: UUID = UUID()) -> (UtteranceAudioRecorder, URL) {
        let cache = UtteranceAudioCache(rootDirectory: tempRoot)
        let directory = cache.sessionDirectory(for: sessionID)
        return (UtteranceAudioRecorder(directory: directory), directory)
    }

    private func files(in directory: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
    }

    /// 書き込み中は .part、次の発話の先頭チャンク到着で前の発話が .wav へ完結する。
    func testRecorderFinalizesOnUtteranceChange() {
        let (recorder, directory) = makeRecorder()
        let first = UUID()
        let second = UUID()
        let chunk1 = Data(repeating: 1, count: 480)
        let chunk2 = Data(repeating: 2, count: 480)

        recorder.append(utteranceID: first, pcm: chunk1)
        recorder.append(utteranceID: first, pcm: chunk2)
        recorder.waitUntilIdle()
        XCTAssertEqual(files(in: directory), [first.uuidString + ".part"])

        recorder.append(utteranceID: second, pcm: chunk1)
        recorder.waitUntilIdle()
        XCTAssertEqual(
            files(in: directory),
            [first.uuidString + ".wav", second.uuidString + ".part"])

        // 完結ファイルは全チャンクの連結が payload として読める
        let cache = UtteranceAudioCache(rootDirectory: tempRoot)
        XCTAssertEqual(cache.pcmPayload(utteranceID: first), chunk1 + chunk2)
        // .part は再生対象にしない
        XCTAssertNil(cache.audioFileURL(utteranceID: second))
    }

    /// endStream 後のキュー読み切り（finishCurrent）で最後の発話が完結する。
    func testRecorderFinishCurrent() {
        let (recorder, directory) = makeRecorder()
        let id = UUID()
        recorder.append(utteranceID: id, pcm: Data(repeating: 3, count: 100))
        recorder.finishCurrent()
        recorder.waitUntilIdle()
        XCTAssertEqual(files(in: directory), [id.uuidString + ".wav"])
    }

    /// stopNow / shutdown（abandonCurrent）では .part をそのまま残す（未完マーカー）。
    func testRecorderAbandonLeavesPart() {
        let (recorder, directory) = makeRecorder()
        let id = UUID()
        recorder.append(utteranceID: id, pcm: Data(repeating: 4, count: 100))
        recorder.abandonCurrent()
        recorder.waitUntilIdle()
        XCTAssertEqual(files(in: directory), [id.uuidString + ".part"])

        // 中断後の別発話は普通に保存できる
        let next = UUID()
        recorder.append(utteranceID: next, pcm: Data(repeating: 5, count: 100))
        recorder.finishCurrent()
        recorder.waitUntilIdle()
        XCTAssertEqual(
            files(in: directory),
            [id.uuidString + ".part", next.uuidString + ".wav"])
    }

    /// 取得失敗した発話は完結させず、以後のチャンクも捨てる（音声が欠けた発話を保存しない）。
    func testRecorderMarkFailedDropsUtterance() {
        let (recorder, directory) = makeRecorder()
        let failed = UUID()
        recorder.append(utteranceID: failed, pcm: Data(repeating: 6, count: 100))
        recorder.markFailed(utteranceID: failed)
        recorder.append(utteranceID: failed, pcm: Data(repeating: 7, count: 100))
        recorder.finishCurrent()
        recorder.waitUntilIdle()
        XCTAssertEqual(files(in: directory), [failed.uuidString + ".part"])

        // 1 文目が丸ごと失敗（ファイル未作成のまま markFailed）でも、以後のチャンクを捨てる
        let failedBeforeOpen = UUID()
        recorder.markFailed(utteranceID: failedBeforeOpen)
        recorder.append(utteranceID: failedBeforeOpen, pcm: Data(repeating: 8, count: 100))
        recorder.finishCurrent()
        recorder.waitUntilIdle()
        XCTAssertFalse(
            files(in: directory).contains(failedBeforeOpen.uuidString + ".wav"))
    }

    /// チャンクが 1 つも無かった発話は空ファイルを残さない。
    func testRecorderRemovesEmptyUtteranceFile() {
        let (recorder, directory) = makeRecorder()
        let empty = UUID()
        recorder.append(utteranceID: empty, pcm: Data())
        recorder.finishCurrent()
        recorder.waitUntilIdle()
        XCTAssertEqual(files(in: directory), [])
    }

    // MARK: - 掃除の対象選別

    func testDirectoryNamesToDelete() {
        let keep = UUID()
        let other1 = UUID().uuidString
        let other2 = UUID().uuidString
        XCTAssertEqual(
            Set(UtteranceAudioCache.directoryNamesToDelete(
                existing: [keep.uuidString, other1, other2], keeping: keep)),
            [other1, other2])
        // keeping = nil は全削除
        XCTAssertEqual(
            Set(UtteranceAudioCache.directoryNamesToDelete(
                existing: [other1, other2], keeping: nil)),
            [other1, other2])
    }

    /// トリガ 1（セッション開始時）: 残す sessionID 以外のディレクトリを丸ごと消す。
    func testPurgeKeepsOnlyGivenSession() throws {
        let cache = UtteranceAudioCache(rootDirectory: tempRoot)
        let keep = UUID()
        let old = UUID()
        for sessionID in [keep, old] {
            let directory = cache.sessionDirectory(for: sessionID)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try Data(repeating: 0, count: 10).write(
                to: directory.appendingPathComponent(UUID().uuidString + ".wav"))
        }
        cache.purge(keepingSessionID: keep)
        XCTAssertEqual(files(in: tempRoot), [keep.uuidString])
    }

    /// 管理画面「容量」の全削除ボタン（docs/plans/archive/chat-storage-audit.md Phase 2）:
    /// keepingSessionID = nil で全セッション分のディレクトリが消える。
    func testPurgeWithoutKeepingSessionRemovesEverything() throws {
        let cache = UtteranceAudioCache(rootDirectory: tempRoot)
        for sessionID in [UUID(), UUID()] {
            let directory = cache.sessionDirectory(for: sessionID)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try Data(repeating: 0, count: 10).write(
                to: directory.appendingPathComponent(UUID().uuidString + ".wav"))
        }
        cache.purge(keepingSessionID: nil)
        XCTAssertEqual(files(in: tempRoot), [])
    }

    /// トリガ 2（起動時）: 最新セッション以外を消し、残したディレクトリ内の .part も消す。
    func testCleanUpAtLaunchRemovesPartsInKeptSession() throws {
        let cache = UtteranceAudioCache(rootDirectory: tempRoot)
        let keep = UUID()
        let old = UUID()
        let keptDirectory = cache.sessionDirectory(for: keep)
        try FileManager.default.createDirectory(
            at: keptDirectory, withIntermediateDirectories: true)
        let complete = UUID().uuidString + ".wav"
        try Data(repeating: 0, count: 10).write(
            to: keptDirectory.appendingPathComponent(complete))
        try Data(repeating: 0, count: 10).write(
            to: keptDirectory.appendingPathComponent(UUID().uuidString + ".part"))
        try FileManager.default.createDirectory(
            at: cache.sessionDirectory(for: old), withIntermediateDirectories: true)

        cache.cleanUpAtLaunch(keepingSessionID: keep)
        XCTAssertEqual(files(in: tempRoot), [keep.uuidString])
        XCTAssertEqual(files(in: keptDirectory), [complete])
    }
}
