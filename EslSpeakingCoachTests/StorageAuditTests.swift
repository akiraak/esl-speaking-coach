import XCTest
@testable import EslSpeakingCoach

/// ストレージ棚卸し（docs/plans/archive/chat-storage-audit.md）: 選別の純関数・サイズ集計・
/// エクスポート残骸の掃除・レコード件数のテスト。
final class StorageAuditTests: XCTestCase {
    private var fixtureRoot: URL!

    override func setUpWithError() throws {
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageAuditTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fixtureRoot)
    }

    private func write(_ relativePath: String, byteCount: Int) throws -> URL {
        let url = fixtureRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: byteCount).write(to: url)
        return url
    }

    // MARK: - 選別（純関数）

    /// 本体とジャーナルは分けて数える（ジャーナルは高水位で頭打ちなので蓄積量の指標にしない）。
    func testSwiftDataFileClassification() {
        XCTAssertTrue(StorageAudit.isSwiftDataStoreFile("default.store"))
        XCTAssertFalse(StorageAudit.isSwiftDataStoreFile("default.store-wal"))
        XCTAssertFalse(StorageAudit.isSwiftDataStoreFile("app.log"))

        XCTAssertTrue(StorageAudit.isSwiftDataJournalFile("default.store-wal"))
        XCTAssertTrue(StorageAudit.isSwiftDataJournalFile("default.store-shm"))
        XCTAssertFalse(StorageAudit.isSwiftDataJournalFile("default.store"))
        XCTAssertFalse(StorageAudit.isSwiftDataJournalFile("Diagnostics"))
    }

    func testIsExportFileName() {
        XCTAssertTrue(SessionExporter.isExportFileName("esl-sessions-20260801-120000.json"))
        XCTAssertFalse(SessionExporter.isExportFileName("esl-sessions-20260801.txt"))
        XCTAssertFalse(SessionExporter.isExportFileName("other.json"))
    }

    // MARK: - サイズ集計

    func testTopLevelFilesSizeCountsOnlyMatchingFiles() throws {
        _ = try write("default.store", byteCount: 100)
        _ = try write("default.store-wal", byteCount: 30)
        _ = try write("default.store-shm", byteCount: 20)
        _ = try write("unrelated.txt", byteCount: 999)
        // サブディレクトリ内は対象外（直下のみ）
        _ = try write("Diagnostics/default.store", byteCount: 999)

        let store = StorageAudit.topLevelFilesSize(
            in: fixtureRoot, matching: StorageAudit.isSwiftDataStoreFile)
        XCTAssertEqual(store.bytes, 100)
        XCTAssertEqual(store.fileCount, 1)

        let journal = StorageAudit.topLevelFilesSize(
            in: fixtureRoot, matching: StorageAudit.isSwiftDataJournalFile)
        XCTAssertEqual(journal.bytes, 50)
        XCTAssertEqual(journal.fileCount, 2)
    }

    func testDirectorySizeIsRecursiveAndZeroWhenMissing() throws {
        _ = try write("UtteranceAudio/session-a/one.wav", byteCount: 44 + 100)
        _ = try write("UtteranceAudio/session-a/two.part", byteCount: 44)
        _ = try write("UtteranceAudio/session-b/three.wav", byteCount: 44 + 50)

        let measured = StorageAudit.directorySize(
            at: fixtureRoot.appendingPathComponent("UtteranceAudio"))
        XCTAssertEqual(measured.bytes, Int64(44 + 100 + 44 + 44 + 50))
        XCTAssertEqual(measured.fileCount, 3)

        let missing = StorageAudit.directorySize(
            at: fixtureRoot.appendingPathComponent("no-such-directory"))
        XCTAssertEqual(missing.bytes, 0)
        XCTAssertEqual(missing.fileCount, 0)
    }

    func testMeasureBuildsReportFromInjectedRoots() throws {
        _ = try write("support/default.store", byteCount: 200)
        _ = try write("support/default.store-wal", byteCount: 50)
        _ = try write("support/Diagnostics/app.log", byteCount: 70)
        _ = try write("audio/session-a/one.wav", byteCount: 300)
        _ = try write("tmp/esl-sessions-20260801-120000.json", byteCount: 40)
        _ = try write("tmp/keep.txt", byteCount: 999)

        let report = StorageAudit.measure(
            applicationSupport: fixtureRoot.appendingPathComponent("support"),
            audioCacheRoot: fixtureRoot.appendingPathComponent("audio"),
            temporary: fixtureRoot.appendingPathComponent("tmp"))

        XCTAssertEqual(report.database.bytes, 200)
        XCTAssertEqual(report.database.fileCount, 1)
        XCTAssertEqual(report.databaseJournal.bytes, 50)
        XCTAssertEqual(report.diagnostics.bytes, 70)
        XCTAssertEqual(report.audioCache.bytes, 300)
        XCTAssertEqual(report.exportLeftovers.bytes, 40)
        XCTAssertEqual(report.exportLeftovers.fileCount, 1)
        XCTAssertEqual(report.totalBytes, 200 + 50 + 70 + 300 + 40)
    }

    // MARK: - 表示

    func testFormattedBytes() {
        XCTAssertEqual(StorageAudit.formattedBytes(0), "0 B")
        XCTAssertEqual(StorageAudit.formattedBytes(512), "512 B")
        XCTAssertEqual(StorageAudit.formattedBytes(2048), "2 KB")
        XCTAssertEqual(StorageAudit.formattedBytes(5 * 1024 * 1024), "5.00 MB")
        XCTAssertEqual(StorageAudit.formattedBytes(200 * 1024 * 1024), "200.0 MB")
        XCTAssertEqual(StorageAudit.formattedBytes(3 * 1024 * 1024 * 1024), "3.00 GB")
    }

    // MARK: - エクスポート残骸の掃除

    func testCleanUpLeftoversRemovesOnlyExportFiles() throws {
        let leftover = try write("esl-sessions-20260801-120000.json", byteCount: 10)
        let unrelated = try write("keep.txt", byteCount: 10)
        let directory = fixtureRoot.appendingPathComponent(
            "esl-sessions-20260801-130000.json", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        SessionExporter.cleanUpLeftovers(in: fixtureRoot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    // MARK: - レコード件数

    @MainActor
    func testRecordCounts() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let historyStore = ChatHistoryStore(container: container)
        let usageStore = UsageStore(container: container)

        historyStore.beginSession(id: UUID(), topicTitle: "Morning routines")
        historyStore.appendMessage(id: UUID(), speaker: .user, text: "Hi.")
        historyStore.appendMessage(id: UUID(), speaker: .chobi, text: "Hello!")
        historyStore.appendLog(kind: .metrics, text: "TTFT 900ms")
        historyStore.endActiveSession()
        usageStore.record(
            AIUsageEvent(
                provider: .anthropic, model: "claude-sonnet-5", kind: .conversationTurn,
                inputTokens: 100, outputTokens: 50),
            sessionID: nil)

        let counts = historyStore.recordCounts()
        XCTAssertEqual(counts.sessions, 1)
        XCTAssertEqual(counts.messages, 2)
        XCTAssertEqual(counts.logs, 1)
        XCTAssertEqual(usageStore.recordCount(), 1)
    }
}
