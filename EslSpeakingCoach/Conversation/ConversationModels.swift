import Foundation

/// セッション先頭に置く user 制御メッセージ（[Memory: ...] + [New topic: ...]）の合成。
/// 通常開始（TurnBasedVoiceSession.startInitialTopicIfNeeded）とエラー後の再開
/// （ChatRoomStore.rebuildHistory）で同じ形になるようここに集約する。
enum SessionOpeningMessage {
    /// 記憶ノートが空（未生成・空白のみ）のときは Memory 部を省略して [New topic: X] のみ。
    static func compose(topic: String, memoryNote: String?) -> String {
        let topicLine = "[New topic: \(topic)]"
        guard let note = memoryNote?.trimmingCharacters(in: .whitespacesAndNewlines),
              !note.isEmpty
        else {
            return topicLine
        }
        return "[Memory: \(note)]\n" + topicLine
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
