import Foundation
import OSLog
import SwiftData

/// キャラのセッション横断記憶（ローリング記憶ノート）。常に単一レコードを上書きする。
/// docs/plans/character-memory.md の「記憶ノートの設計」に対応する。
@Model
final class CharacterMemoryRecord {
    /// 英語の箇条書きノート 1 本（MemoryUpdateClient が生成）
    var text: String
    var updatedAt: Date
    /// このノートを生成したセッション（デバッグ用の由来情報）
    var sourceSessionID: UUID?

    init(text: String, updatedAt: Date = Date(), sourceSessionID: UUID?) {
        self.text = text
        self.updatedAt = updatedAt
        self.sourceSessionID = sourceSessionID
    }
}

/// 記憶ノートの読み書きストア。ChatRoomStore（セッション開始時の読み込み・終了時の上書き）と
/// 管理画面（閲覧・リセット）から使う。保存は best effort: 失敗しても会話は継続する。
@MainActor
final class CharacterMemoryStore {
    /// 管理画面用の値型スナップショット（@Model を View 側へ持ち出さない）。
    struct MemorySnapshot: Sendable {
        let text: String
        let updatedAt: Date
        let sourceSessionID: UUID?
    }

    private static let logger = Logger(
        subsystem: "com.akiraak.EslSpeakingCoach", category: "CharacterMemoryStore")

    private let context: ModelContext

    init(container: ModelContainer) {
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    /// 現在の記憶ノート本文（未生成なら nil）。セッション開始時の注入用。
    func currentNote() -> String? {
        fetchRecord()?.text
    }

    /// 管理画面用: 記憶の全情報（未生成なら nil）。
    func snapshot() -> MemorySnapshot? {
        guard let record = fetchRecord() else { return nil }
        return MemorySnapshot(
            text: record.text,
            updatedAt: record.updatedAt,
            sourceSessionID: record.sourceSessionID)
    }

    /// 更新済みノートで単一レコードを上書きする（無ければ作成）。
    func save(text: String, sourceSessionID: UUID?, at updatedAt: Date = Date()) {
        if let record = fetchRecord() {
            record.text = text
            record.updatedAt = updatedAt
            record.sourceSessionID = sourceSessionID
        } else {
            context.insert(CharacterMemoryRecord(
                text: text, updatedAt: updatedAt, sourceSessionID: sourceSessionID))
        }
        save()
    }

    /// 管理画面用: 記憶を消してキャラを白紙に戻す。
    func reset() {
        // 想定は単一レコードだが、万一複数残っていても全部消す
        for record in fetchRecords() {
            context.delete(record)
        }
        save()
    }

    // MARK: - private

    private func fetchRecord() -> CharacterMemoryRecord? {
        fetchRecords().first
    }

    private func fetchRecords() -> [CharacterMemoryRecord] {
        let descriptor = FetchDescriptor<CharacterMemoryRecord>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }

    private func save() {
        do {
            try context.save()
        } catch {
            Self.logger.error("記憶ノートの保存に失敗: \(error.localizedDescription)")
        }
    }
}
