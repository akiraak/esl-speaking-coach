import Foundation
import OSLog
import SwiftData

/// AI API 1 呼び出し分の利用記録。生の usage と、記録時に計算した推定額を持つ。
@Model
final class APIUsageRecord {
    var timestamp: Date
    var providerRawValue: String
    var model: String
    var kindRawValue: String
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheReadTokens: Int?
    var cacheWriteTokens: Int?
    var audioInputTokens: Int?
    var audioSeconds: Double?
    /// 記録時の単価表（AIPricing）で計算した推定額。表示はこの合算のみで再計算しない
    var estimatedCostUSD: Double
    /// 会話セッションに紐づく呼び出しのみ（トピック生成等は nil）
    var sessionID: UUID?

    init(event: AIUsageEvent, estimatedCostUSD: Double, sessionID: UUID?, timestamp: Date) {
        self.timestamp = timestamp
        self.providerRawValue = event.provider.rawValue
        self.model = event.model
        self.kindRawValue = event.kind.rawValue
        self.inputTokens = event.inputTokens
        self.outputTokens = event.outputTokens
        self.cacheReadTokens = event.cacheReadTokens
        self.cacheWriteTokens = event.cacheWriteTokens
        self.audioInputTokens = event.audioInputTokens
        self.audioSeconds = event.audioSeconds
        self.estimatedCostUSD = estimatedCostUSD
        self.sessionID = sessionID
    }

    var kind: AIUsageEvent.Kind? {
        AIUsageEvent.Kind(rawValue: kindRawValue)
    }
}

/// AI 利用量の記録と集計（管理画面「AI 利用料金」用）。記録は best effort。
@MainActor
final class UsageStore {
    struct Totals: Sendable {
        var todayUSD = 0.0
        var thisMonthUSD = 0.0
        var allTimeUSD = 0.0
        var recordCount = 0
    }

    struct KindTotal: Identifiable, Sendable {
        let kind: AIUsageEvent.Kind
        let costUSD: Double
        var id: String { kind.rawValue }
    }

    struct DailyTotal: Identifiable, Sendable {
        let day: Date
        let costUSD: Double
        var id: Date { day }
    }

    private static let logger = Logger(subsystem: "com.akiraak.EslSpeakingCoach", category: "UsageStore")

    private let context: ModelContext
    private let calendar = Calendar.current

    init(container: ModelContainer) {
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    func record(_ event: AIUsageEvent, sessionID: UUID?, at timestamp: Date = Date()) {
        let cost = AIPricing.estimatedCostUSD(for: event, at: timestamp)
        let record = APIUsageRecord(
            event: event, estimatedCostUSD: cost, sessionID: sessionID, timestamp: timestamp)
        context.insert(record)
        do {
            try context.save()
        } catch {
            Self.logger.error("利用量の記録に失敗: \(error.localizedDescription)")
        }
    }

    // MARK: - 集計

    func totals(now: Date = Date()) -> Totals {
        let records = fetchAll()
        var totals = Totals()
        totals.recordCount = records.count
        let today = calendar.startOfDay(for: now)
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? today
        for record in records {
            totals.allTimeUSD += record.estimatedCostUSD
            if record.timestamp >= monthStart { totals.thisMonthUSD += record.estimatedCostUSD }
            if record.timestamp >= today { totals.todayUSD += record.estimatedCostUSD }
        }
        return totals
    }

    /// 種別ごとの累計（金額の大きい順）。
    func kindTotals() -> [KindTotal] {
        var sums: [AIUsageEvent.Kind: Double] = [:]
        for record in fetchAll() {
            guard let kind = record.kind else { continue }
            sums[kind, default: 0] += record.estimatedCostUSD
        }
        return sums.map { KindTotal(kind: $0.key, costUSD: $0.value) }
            .sorted { $0.costUSD > $1.costUSD }
    }

    /// 直近 days 日の日別合計（新しい日が先頭。利用のなかった日は含まない）。
    func dailyTotals(days: Int, now: Date = Date()) -> [DailyTotal] {
        guard let since = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now))
        else { return [] }
        var sums: [Date: Double] = [:]
        for record in fetchAll() where record.timestamp >= since {
            let day = calendar.startOfDay(for: record.timestamp)
            sums[day, default: 0] += record.estimatedCostUSD
        }
        return sums.map { DailyTotal(day: $0.key, costUSD: $0.value) }
            .sorted { $0.day > $1.day }
    }

    func sessionCostUSD(sessionID: UUID) -> Double {
        let descriptor = FetchDescriptor<APIUsageRecord>(
            predicate: #Predicate { $0.sessionID == sessionID })
        let records = (try? context.fetch(descriptor)) ?? []
        return records.reduce(0) { $0 + $1.estimatedCostUSD }
    }

    /// セッション削除時に紐づく記録も消す（管理画面から）。
    func deleteRecords(sessionID: UUID) {
        let descriptor = FetchDescriptor<APIUsageRecord>(
            predicate: #Predicate { $0.sessionID == sessionID })
        for record in (try? context.fetch(descriptor)) ?? [] {
            context.delete(record)
        }
        try? context.save()
    }

    private func fetchAll() -> [APIUsageRecord] {
        let descriptor = FetchDescriptor<APIUsageRecord>(
            sortBy: [SortDescriptor(\.timestamp, order: .forward)])
        return (try? context.fetch(descriptor)) ?? []
    }
}
