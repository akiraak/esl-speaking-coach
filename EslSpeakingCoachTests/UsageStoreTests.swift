import XCTest
@testable import EslSpeakingCoach

@MainActor
final class UsageStoreTests: XCTestCase {
    private func makeStore() throws -> UsageStore {
        UsageStore(container: try AppModelContainer.make(inMemory: true))
    }

    private func turnEvent(outputTokens: Int = 100) -> AIUsageEvent {
        AIUsageEvent(
            provider: .anthropic, model: "claude-sonnet-5", kind: .conversationTurn,
            inputTokens: 1_000, outputTokens: outputTokens)
    }

    func testTotalsAggregateByPeriod() throws {
        let store = try makeStore()
        let now = ISO8601DateFormatter().date(from: "2026-07-25T12:00:00Z")!
        let calendar = Calendar.current

        store.record(turnEvent(), sessionID: nil, at: now)
        store.record(turnEvent(), sessionID: nil, at: calendar.date(byAdding: .day, value: -3, to: now)!)
        store.record(turnEvent(), sessionID: nil, at: calendar.date(byAdding: .month, value: -2, to: now)!)

        let totals = store.totals(now: now)
        XCTAssertEqual(totals.recordCount, 3)
        // sonnet-5 導入価格: 入力 1K × $2/M + 出力 100 × $10/M = $0.003
        let perRecord = 0.003
        XCTAssertEqual(totals.todayUSD, perRecord, accuracy: 0.000001)
        XCTAssertEqual(totals.allTimeUSD, perRecord * 3, accuracy: 0.000001)
        XCTAssertGreaterThanOrEqual(totals.thisMonthUSD, perRecord)
        XCTAssertLessThan(totals.thisMonthUSD, perRecord * 3)
    }

    /// 種別内訳は今月分のみを金額降順で返す（先月以前の記録は含めない）。
    /// 今月利用のない種別も $0 で全種別が並ぶ（同額は Kind.allCases の定義順）。
    func testKindTotalsSortedByCostWithinMonthListingAllKinds() throws {
        let store = try makeStore()
        let now = ISO8601DateFormatter().date(from: "2026-07-25T12:00:00Z")!
        store.record(turnEvent(outputTokens: 100), sessionID: nil, at: now)
        store.record(
            AIUsageEvent(
                provider: .gemini, model: "gemini-3.1-flash-tts-preview", kind: .textToSpeech,
                inputTokens: 30, outputTokens: 100_000),
            sessionID: nil, at: now)
        store.record(
            AIUsageEvent(
                provider: .anthropic, model: "claude-sonnet-5", kind: .sessionFeedback,
                inputTokens: 5_000, outputTokens: 3_000),
            sessionID: nil, at: Calendar.current.date(byAdding: .month, value: -2, to: now)!)

        let kinds = store.kindTotals(monthOf: now)
        XCTAssertEqual(
            kinds.map(\.kind),
            [
                .textToSpeech, .conversationTurn,
                .speechToText, .topicSuggestion, .sessionFeedback, .memoryUpdate, .translation,
            ])
        // 先月以前しか記録のないフィードバック生成は $0 になる
        XCTAssertEqual(kinds.first { $0.kind == .sessionFeedback }?.costUSD, 0)
    }

    func testSessionCostAndDeletion() throws {
        let store = try makeStore()
        let sessionID = UUID()
        store.record(turnEvent(), sessionID: sessionID)
        store.record(turnEvent(), sessionID: sessionID)
        store.record(turnEvent(), sessionID: nil)

        XCTAssertEqual(store.sessionCostUSD(sessionID: sessionID), 0.006, accuracy: 0.000001)

        store.deleteRecords(sessionID: sessionID)
        XCTAssertEqual(store.sessionCostUSD(sessionID: sessionID), 0)
        // セッションに紐づかない記録は残る
        XCTAssertEqual(store.totals().recordCount, 1)
    }

    func testDailyTotalsGroupsByDay() throws {
        let store = try makeStore()
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        store.record(turnEvent(), sessionID: nil, at: now)
        store.record(turnEvent(), sessionID: nil, at: now)
        store.record(turnEvent(), sessionID: nil, at: yesterday)

        let daily = store.dailyTotals(days: 30, now: now)
        XCTAssertEqual(daily.count, 2)
        XCTAssertEqual(daily[0].costUSD, 0.006, accuracy: 0.000001)
        XCTAssertEqual(daily[1].costUSD, 0.003, accuracy: 0.000001)
    }
}
