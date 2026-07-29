import Foundation

/// セッション先頭に置く user 制御メッセージ（[Memory: ...] + [New topic: ...] / [New word: ...]）の合成。
/// 通常開始（TurnBasedVoiceSession.startOpeningIfNeeded）とエラー後の再開
/// （ChatRoomStore.rebuildHistory）で同じ形になるようここに集約する。
enum SessionOpeningMessage {
    /// AI が口火を切る開始（`Opening.assistantFirst`）。
    /// 記憶ノートが空（未生成・空白のみ）のときは Memory 部を省略して [New topic: X] のみ。
    /// 単語モードは記憶ノートを渡されても混ぜず、常に [New word: X] の 1 行だけになる。
    static func compose(
        mode: PracticeMode = .conversation, topic: String, memoryNote: String?
    ) -> String {
        let topicLine = "[\(mode.openingControlKey): \(topic)]"
        guard mode.injectsMemoryNote,
              let memoryLine = composeMemoryOnly(memoryNote: memoryNote)
        else {
            return topicLine
        }
        return memoryLine + "\n" + topicLine
    }

    /// 学習者から始める開始（`Opening.learnerFirst`）。トピックを渡さないので [Memory: ...] だけを積む。
    /// ノートが空なら nil = 何も積まない（履歴は学習者の第一声から始まる）。
    static func composeMemoryOnly(memoryNote: String?) -> String? {
        guard let note = memoryNote?.trimmingCharacters(in: .whitespacesAndNewlines),
              !note.isEmpty
        else {
            return nil
        }
        return "[Memory: \(note)]"
    }
}

/// プロバイダ非依存の会話履歴モデル。
/// API のリクエスト型をそのまま持ち回らない（CLAUDE.md の設計制約）。
struct ConversationMessage: Identifiable, Sendable, Equatable {
    enum Role: String, Sendable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    var text: String

    init(role: Role, text: String) {
        self.id = UUID()
        self.role = role
        self.text = text
    }
}
