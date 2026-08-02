import Foundation

/// 全セッションを JSON へ書き出す（モデル評価の fixture 用。
/// docs/plans/cheap-chinese-ai-models.md の Phase 5 Step 0）。導線は DEBUG の管理画面のみ。
/// 形式は端末内モデルの素直な写しで、API 履歴への再構築（台本タグの再直列化・開始の
/// 制御メッセージ合成）は評価スクリプト側で `ChatRoomStore.rebuildHistory` と同じ規則で行う。
@MainActor
enum SessionExporter {
    struct Export: Codable {
        let exportedAt: Date
        /// 現在の記憶ノート。セッション当時の値は保存されていないため近似としてのみ使える
        let memoryNote: String?
        let sessions: [Session]
    }

    struct Session: Codable {
        let id: UUID
        let topicTitle: String
        /// `SessionKind.rawValue`（conversation / word / quiz）
        let kind: String
        let startedAt: Date
        let endedAt: Date?
        let messages: [Message]
        let logs: [Log]
        let feedback: SessionFeedback?
    }

    struct Message: Codable {
        /// `MessageSpeaker.rawValue`（user / chobi / naruko）
        let speaker: String
        let text: String
        let translation: String?
        let createdAt: Date
    }

    struct Log: Codable {
        /// `SessionLogKind.rawValue`（metrics / notice / error）
        let kind: String
        let text: String
        let createdAt: Date
    }

    /// tmp に書き出したファイルの名前か（掃除の対象選別。純関数）。
    nonisolated static func isExportFileName(_ name: String) -> Bool {
        name.hasPrefix("esl-sessions-") && name.hasSuffix(".json")
    }

    /// tmp のエクスポート残骸を削除する（docs/plans/archive/chat-storage-audit.md Phase 2）。
    /// 書き出しは共有シートで渡し終えたら用済みなので、シートを閉じたときと起動時に呼ぶ。
    nonisolated static func cleanUpLeftovers(
        in directory: URL = FileManager.default.temporaryDirectory
    ) {
        let fileManager = FileManager.default
        let urls = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in urls where isExportFileName(url.lastPathComponent) {
            try? fileManager.removeItem(at: url)
        }
    }

    /// 全セッションを JSON にエンコードして一時ファイルへ書き出し、その URL を返す。
    static func writeJSON(
        historyStore: ChatHistoryStore, memoryStore: CharacterMemoryStore
    ) throws -> URL {
        let export = buildExport(historyStore: historyStore, memoryStore: memoryStore)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(export)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("esl-sessions-\(formatter.string(from: export.exportedAt)).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// エンコード対象の組み立て（古い順）。
    static func buildExport(
        historyStore: ChatHistoryStore, memoryStore: CharacterMemoryStore
    ) -> Export {
        let sessions = historyStore.sessionSummaries().reversed().map { summary in
            Session(
                id: summary.id,
                topicTitle: summary.topicTitle,
                kind: summary.kind.rawValue,
                startedAt: summary.startedAt,
                endedAt: summary.endedAt,
                messages: historyStore.messages(sessionID: summary.id).map { message in
                    Message(
                        speaker: message.speaker.rawValue,
                        text: message.text,
                        translation: message.translation,
                        createdAt: message.createdAt)
                },
                logs: historyStore.logs(sessionID: summary.id).map { log in
                    Log(kind: log.kind.rawValue, text: log.text, createdAt: log.createdAt)
                },
                feedback: historyStore.feedback(sessionID: summary.id))
        }
        return Export(
            exportedAt: Date(),
            memoryNote: memoryStore.currentNote(),
            sessions: Array(sessions))
    }
}
