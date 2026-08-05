import Foundation

/// セッションへ注入する記憶ノート 3 本（docs/plans/archive/per-character-memory.md）。
/// 学習者ノートは 2 キャラ共有、キャラノートは自分自身のことだけ。
/// **キャラのノートは両方注入する** ―― 2 人は同席していて互いの話も聞いているので、
/// 片方だけ渡すと相手の近況に相槌が打てない。
struct MemoryNotes: Sendable, Equatable {
    /// 学習者の事実 + 直近セッション要約
    var learner: String?
    var chobi: String?
    var naruko: String?

    static let empty = MemoryNotes()

    init(learner: String? = nil, chobi: String? = nil, naruko: String? = nil) {
        self.learner = learner
        self.chobi = chobi
        self.naruko = naruko
    }

    subscript(scope: MemoryScope) -> String? {
        switch scope {
        case .shared: return learner
        case .character(.chobi): return chobi
        case .character(.naruko): return naruko
        }
    }

    /// 3 本とも空（未生成・空白のみ）= 記憶なし。
    var isEmpty: Bool {
        MemoryScope.allCases.allSatisfy { SessionOpeningMessage.trimmed(self[$0]) == nil }
    }
}

/// セッション先頭に置く user 制御メッセージ（[Memory: ...] + [New topic: ...] / [New word: ...]）の合成。
/// 通常開始（TurnBasedVoiceSession.startOpeningIfNeeded）とエラー後の再開
/// （ChatRoomStore.rebuildHistory）で同じ形になるようここに集約する。
enum SessionOpeningMessage {
    /// AI が口火を切る開始（`Opening.assistantFirst`）。
    /// 記憶ノートが空（未生成・空白のみ）の行は省略し、3 本とも空なら [New topic: X] のみ。
    /// 単語・クイズは記憶ノートを渡されても混ぜず、常に [New word: X] / [Quiz words: X] の
    /// 1 行だけになる。
    static func compose(
        kind: SessionKind = .conversation, topic: String, memoryNotes: MemoryNotes
    ) -> String {
        let topicLine = "[\(kind.openingControlKey): \(topic)]"
        guard kind.usesMemoryNote,
              let memoryLines = composeMemoryOnly(memoryNotes: memoryNotes)
        else {
            return topicLine
        }
        return memoryLines + "\n" + topicLine
    }

    /// 学習者から始める開始（`Opening.learnerFirst`）。トピックを渡さないので Memory 行だけを積む。
    /// 3 本とも空なら nil = 何も積まない（履歴は学習者の第一声から始まる）。
    static func composeMemoryOnly(memoryNotes: MemoryNotes) -> String? {
        let lines = MemoryScope.allCases.compactMap { scope -> String? in
            guard let note = trimmed(memoryNotes[scope]) else { return nil }
            return "[\(scope.openingControlKey): \(note)]"
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// 前後の空白を落とし、空文字なら nil（= その行は積まない）。
    static func trimmed(_ note: String?) -> String? {
        guard let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty
        else {
            return nil
        }
        return note
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
