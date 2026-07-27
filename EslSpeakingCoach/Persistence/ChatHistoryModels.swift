import Foundation
import SwiftData

/// 会話履歴の話者。conversation-design.md の「speaker 付き履歴モデル」に対応する
/// （user / chobi / naruko。AI の台本はタグでパース済みの speaker 別発話として保存する）。
enum MessageSpeaker: String, Sendable {
    case user
    case chobi
    case naruko

    init(character: ChatCharacter) {
        switch character {
        case .chobi: self = .chobi
        case .naruko: self = .naruko
        }
    }

    /// user は nil。
    var character: ChatCharacter? {
        switch self {
        case .user: return nil
        case .chobi: return .chobi
        case .naruko: return .naruko
        }
    }
}

/// 1 トピック分の会話セッション（区切り〜終了まで）。端末内のみ・iCloud 同期なし。
@Model
final class ChatSessionRecord {
    @Attribute(.unique) var id: UUID
    var topicTitle: String
    var startedAt: Date
    /// nil はセッション中（アプリ強制終了で残った場合は次回起動時に閉じる）
    var endedAt: Date?
    /// 生成済みフィードバック（SessionFeedback の JSON encode。未生成 / スキップは nil）
    var feedbackJSON: Data?
    @Relationship(deleteRule: .cascade, inverse: \ChatMessageRecord.session)
    var messages: [ChatMessageRecord] = []
    /// 調査用のログ（レイテンシ計測・技術通知・エラー）。トーク画面には出さず管理画面でのみ見る
    @Relationship(deleteRule: .cascade, inverse: \ChatSessionLogRecord.session)
    var logs: [ChatSessionLogRecord] = []

    init(id: UUID = UUID(), topicTitle: String, startedAt: Date = Date()) {
        self.id = id
        self.topicTitle = topicTitle
        self.startedAt = startedAt
    }
}

/// セッション内の 1 発話（吹き出し単位・speaker 付き）。
/// id はタイムライン上の発話 ID と一致させる（ストリーミング中のテキスト更新で引くため）。
@Model
final class ChatMessageRecord {
    @Attribute(.unique) var id: UUID
    /// セッション内の表示順（timeline への追加順）
    var orderIndex: Int
    var speakerRawValue: String
    var text: String
    var createdAt: Date
    var session: ChatSessionRecord?

    init(id: UUID, orderIndex: Int, speaker: MessageSpeaker, text: String, createdAt: Date = Date()) {
        self.id = id
        self.orderIndex = orderIndex
        self.speakerRawValue = speaker.rawValue
        self.text = text
        self.createdAt = createdAt
    }

    var speaker: MessageSpeaker? {
        MessageSpeaker(rawValue: speakerRawValue)
    }
}

/// 調査用ログの種別（管理画面の会話ログでの表示分け用）。
enum SessionLogKind: String, Sendable {
    /// 1 ターンのレイテンシ実測値（TurnMetrics の 1 行サマリ）
    case metrics
    /// STT 接続・再接続・stop_reason などの技術通知
    case notice
    /// 会話が止まったエラー（トーク画面にも出す）
    case error
}

/// セッションに紐づく調査用ログの 1 行。会話練習の邪魔になるためトーク画面には出さず、
/// 管理画面のセッション詳細で発話と時系列にマージして表示する。
@Model
final class ChatSessionLogRecord {
    @Attribute(.unique) var id: UUID
    /// セッション内の記録順（同一秒に並んだときの安定した並び用）
    var orderIndex: Int
    var kindRawValue: String
    var text: String
    var createdAt: Date
    var session: ChatSessionRecord?

    init(
        id: UUID = UUID(), orderIndex: Int, kind: SessionLogKind, text: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.orderIndex = orderIndex
        self.kindRawValue = kind.rawValue
        self.text = text
        self.createdAt = createdAt
    }

    var kind: SessionLogKind? {
        SessionLogKind(rawValue: kindRawValue)
    }
}
