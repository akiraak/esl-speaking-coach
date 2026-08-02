import Foundation
import SwiftData
import XCTest
@testable import EslSpeakingCoach

/// SwiftData の永続履歴の掃除（docs/plans/archive/chat-storage-audit.md Phase 2）。
/// 履歴そのものはファイルストアでしか記録されないため、ここでは基準時刻の計算と、
/// 削除が実データを壊さないことを確かめる。実際に行が減ることはシミュレータで実測した。
final class PersistentHistoryCleanerTests: XCTestCase {
    func testCutoffDateGoesBackKeepDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(
            DateComponents(calendar: calendar, year: 2026, month: 8, day: 1, hour: 12).date)

        let cutoff = try XCTUnwrap(
            PersistentHistoryCleaner.cutoffDate(now: now, keepDays: 7, calendar: calendar))
        XCTAssertEqual(cutoff, now.addingTimeInterval(-7 * 24 * 60 * 60))

        // keepDays 0 は「今より前を全部消す」
        XCTAssertEqual(
            PersistentHistoryCleaner.cutoffDate(now: now, keepDays: 0, calendar: calendar), now)
    }

    @MainActor
    func testPurgeKeepsStoredRecords() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let historyStore = ChatHistoryStore(container: container)
        historyStore.beginSession(id: UUID(), topicTitle: "Morning routines")
        historyStore.appendMessage(id: UUID(), speaker: .user, text: "I wake up at six.")
        historyStore.endActiveSession()

        PersistentHistoryCleaner.purgeOldHistory(container: container, keepDays: 0)

        // 履歴を消しても会話は残る（履歴は変更ログであって実データではない）
        let counts = historyStore.recordCounts()
        XCTAssertEqual(counts.sessions, 1)
        XCTAssertEqual(counts.messages, 1)
    }
}
