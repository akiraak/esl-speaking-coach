import Foundation

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
