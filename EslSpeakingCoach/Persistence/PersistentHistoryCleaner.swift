import Foundation
import OSLog
import SwiftData

/// SwiftData が既定で記録する永続履歴（ストア内の ATRANSACTION / ACHANGE テーブル）の掃除
/// （docs/plans/archive/chat-storage-audit.md Phase 2）。
///
/// 履歴は iCloud 同期や別プロセス（Widget / Extension）が変更を追うための変更ログで、
/// このアプリにはどちらも無いので使い道が無い。それでも `ModelConfiguration` に無効化する
/// 手段が無く、保存のたびに増え続ける（実測: 23 セッションで 151KB = ストアの約半分）。
/// 実データが消えるわけではないので、古い分は起動時に捨てて頭打ちにする。
enum PersistentHistoryCleaner {
    /// これより古いトランザクションを消す。直近を残すのは、同一プロセス内の複数
    /// `ModelContext`（会話履歴 / 利用量 / 記憶）の変更マージに SwiftData 自身が使う可能性への保険
    static let defaultKeepDays = 7

    private static let logger = Logger(
        subsystem: "com.akiraak.EslSpeakingCoach", category: "PersistentHistoryCleaner")

    /// 削除の基準時刻（純関数）。
    static func cutoffDate(now: Date, keepDays: Int, calendar: Calendar = .current) -> Date? {
        calendar.date(byAdding: .day, value: -keepDays, to: now)
    }

    /// 基準時刻より古いトランザクションを削除する。失敗しても会話には影響しないので握り潰す。
    static func purgeOldHistory(
        container: ModelContainer, now: Date = Date(), keepDays: Int = defaultKeepDays
    ) {
        guard let cutoff = cutoffDate(now: now, keepDays: keepDays) else { return }
        let context = ModelContext(container)
        let descriptor = HistoryDescriptor<DefaultHistoryTransaction>(
            predicate: #Predicate { $0.timestamp < cutoff })
        do {
            try context.deleteHistory(descriptor)
        } catch {
            logger.error("永続履歴の削除に失敗: \(error.localizedDescription)")
        }
    }
}
