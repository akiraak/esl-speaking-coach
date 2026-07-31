import Foundation
import OSLog
import SwiftData

/// 会話履歴の永続化ストア。ChatRoomStore（書き込み・起動時復元）と管理画面（閲覧・削除）から使う。
/// 保存は best effort: 失敗しても会話は継続する（エラーはログのみ）。
@MainActor
final class ChatHistoryStore {
    /// 管理画面のセッション一覧用サマリ（@Model を View 側へ持ち出さないための値型）。
    struct SessionSummary: Identifiable, Sendable {
        let id: UUID
        let topicTitle: String
        /// セッション種別（単語・クイズのセッションは topicTitle が語そのもの）
        let kind: SessionKind
        let startedAt: Date
        let endedAt: Date?
        let messageCount: Int
        let hasFeedback: Bool
    }

    /// セッション詳細の 1 発話（値型）。
    struct MessageSnapshot: Identifiable, Sendable {
        let id: UUID
        let speaker: MessageSpeaker
        let text: String
        /// 日本語訳（未生成は nil）
        let translation: String?
        let createdAt: Date
    }

    /// セッション詳細の調査用ログ 1 行（値型）。
    struct LogSnapshot: Identifiable, Sendable {
        let id: UUID
        let kind: SessionLogKind
        let text: String
        let createdAt: Date
    }

    private static let logger = Logger(subsystem: "com.akiraak.EslSpeakingCoach", category: "ChatHistoryStore")

    private let context: ModelContext
    /// アクティブセッションと発話のキャッシュ（ストリーミング更新のたびのフェッチを避ける）
    private var activeSession: ChatSessionRecord?
    private var activeMessagesByID: [UUID: ChatMessageRecord] = [:]
    private var nextOrderIndex = 0
    private var nextLogOrderIndex = 0

    init(container: ModelContainer) {
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    // MARK: - 起動時の整理

    /// 前回起動がセッション中に落ちていた場合の後始末。
    /// 発話のあるセッションは最終発話時刻で閉じ、空のセッションは削除する。
    func closeUnfinishedSessions() {
        for session in fetchSessions() where session.endedAt == nil {
            if let lastAt = session.messages.map(\.createdAt).max() {
                session.endedAt = lastAt
            } else {
                context.delete(session)
            }
        }
        save()
    }

    // MARK: - アクティブセッションへの書き込み

    func beginSession(
        id: UUID, topicTitle: String, topicGenre: String? = nil,
        kind: SessionKind = .conversation
    ) {
        let session = ChatSessionRecord(
            id: id, topicTitle: topicTitle, topicGenre: topicGenre, kind: kind)
        context.insert(session)
        activeSession = session
        activeMessagesByID = [:]
        nextOrderIndex = 0
        nextLogOrderIndex = 0
        save()
    }

    /// エラー後の再開用: 既存セッションを再びアクティブにする（メッセージは追記を続ける）。
    func resumeSession(id: UUID) {
        guard activeSession?.id != id else { return }
        guard let session = fetchSession(id: id) else { return }
        activeSession = session
        activeMessagesByID = Dictionary(
            uniqueKeysWithValues: session.messages.map { ($0.id, $0) })
        nextOrderIndex = (session.messages.map(\.orderIndex).max() ?? -1) + 1
        nextLogOrderIndex = (session.logs.map(\.orderIndex).max() ?? -1) + 1
    }

    func appendMessage(id: UUID, speaker: MessageSpeaker, text: String) {
        guard let activeSession else { return }
        let record = ChatMessageRecord(
            id: id, orderIndex: nextOrderIndex, speaker: speaker, text: text)
        nextOrderIndex += 1
        record.session = activeSession
        context.insert(record)
        activeMessagesByID[id] = record
        save()
    }

    /// ストリーミングで伸びた発話テキストの更新（発話 ID で引く）。
    func updateMessageText(id: UUID, text: String) {
        guard let record = activeMessagesByID[id] else { return }
        record.text = text
        save()
    }

    /// 発話の日本語訳を保存する。過去セッション（アクティブ外）の発話も対象なので
    /// キャッシュに無ければ発話 ID で直接フェッチする。
    func updateTranslation(id: UUID, text: String) {
        guard let record = activeMessagesByID[id] ?? fetchMessage(id: id) else { return }
        record.translation = text
        save()
    }

    /// 調査用ログの追記（レイテンシ計測・技術通知・エラー）。
    /// セッション外で起きたものは記録しない（会話ログの一部として見るため）。
    func appendLog(kind: SessionLogKind, text: String) {
        guard let activeSession else { return }
        let record = ChatSessionLogRecord(
            orderIndex: nextLogOrderIndex, kind: kind, text: text)
        nextLogOrderIndex += 1
        record.session = activeSession
        context.insert(record)
        save()
    }

    func endActiveSession() {
        guard let activeSession else { return }
        if activeSession.messages.isEmpty {
            // 何も話さず終了したセッションは残さない
            context.delete(activeSession)
        } else {
            activeSession.endedAt = Date()
        }
        self.activeSession = nil
        activeMessagesByID = [:]
        save()
    }

    func saveFeedback(sessionID: UUID, feedback: SessionFeedback) {
        guard let session = fetchSession(id: sessionID) else { return }
        do {
            session.feedbackJSON = try JSONEncoder().encode(feedback)
            save()
        } catch {
            Self.logger.error("フィードバックの保存に失敗: \(error.localizedDescription)")
        }
    }

    // MARK: - 復元・閲覧

    /// 起動時復元用: 直近 limit セッション（古い順。タイムラインへ上から積む）。
    func recentSessions(limit: Int) -> [ChatSessionRecord] {
        Array(fetchSessions().suffix(limit))
    }

    /// トピック重複回避用の直近タイトル（古い順・最大 limit 件）。
    /// 単語練習のセッションは除く（練習語をトピック生成の除外リストへ混ぜない）。
    func recentTopicTitles(limit: Int) -> [String] {
        fetchSessions().filter { $0.kind == .conversation }.suffix(limit).map(\.topicTitle)
    }

    /// 単語練習モードで練習した語（**新しい順**・最大 limit 件）。
    /// 単語カードの「前に練習した語」ピルの元データ（docs/plans/vocabulary-continuity.md）。
    /// 重複除去は `ChatRoomStore.practicedWordSuggestions` で行うので、ここは履歴のまま返す。
    func recentWords(limit: Int) -> [String] {
        fetchSessions().reversed().filter { $0.kind == .word }.prefix(limit).map(\.topicTitle)
    }

    /// ランダム出題の除外用: 単語練習モードで練習した語の**全件**（docs/plans/wordbook-random-word.md）。
    /// `recentWords(limit:)` と違い件数を絞らない（絞ると古い練習語が「未学習」に化ける）。
    func practicedWordsAll() -> [String] {
        fetchSessions().filter { $0.kind == .word }.map(\.topicTitle)
    }

    /// クイズの出題済み除外用: クイズセッションの `topicTitle`（`", "` 連結）の**全件**
    /// （docs/plans/word-quiz-mode.md）。語への分割は `ChatRoomStore.quizzedWords` で行う。
    func quizzedTitlesAll() -> [String] {
        fetchSessions().filter { $0.kind == .quiz }.map(\.topicTitle)
    }

    /// ジャンル重複回避用の直近ジャンル id（古い順・最大 limit 件）。
    /// ジャンル不明（自作トピック・固定候補）のセッションは含めない。
    func recentTopicGenres(limit: Int) -> [String] {
        Array(fetchSessions().compactMap(\.topicGenre).suffix(limit))
    }

    /// 管理画面用: 全セッションのサマリ（新しい順)。
    func sessionSummaries() -> [SessionSummary] {
        fetchSessions().reversed().map { session in
            SessionSummary(
                id: session.id,
                topicTitle: session.topicTitle,
                kind: session.kind,
                startedAt: session.startedAt,
                endedAt: session.endedAt,
                messageCount: session.messages.count,
                hasFeedback: session.feedbackJSON != nil)
        }
    }

    /// 管理画面用: セッションの発話一覧（表示順）。
    func messages(sessionID: UUID) -> [MessageSnapshot] {
        guard let session = fetchSession(id: sessionID) else { return [] }
        return session.messages
            .sorted { $0.orderIndex < $1.orderIndex }
            .compactMap { record in
                guard let speaker = record.speaker else { return nil }
                return MessageSnapshot(
                    id: record.id, speaker: speaker, text: record.text,
                    translation: record.translation, createdAt: record.createdAt)
            }
    }

    /// 管理画面用: セッションの調査用ログ（記録順）。
    func logs(sessionID: UUID) -> [LogSnapshot] {
        guard let session = fetchSession(id: sessionID) else { return [] }
        return session.logs
            .sorted { $0.orderIndex < $1.orderIndex }
            .compactMap { record in
                guard let kind = record.kind else { return nil }
                return LogSnapshot(
                    id: record.id, kind: kind, text: record.text, createdAt: record.createdAt)
            }
    }

    func feedback(sessionID: UUID) -> SessionFeedback? {
        guard let data = fetchSession(id: sessionID)?.feedbackJSON else { return nil }
        return try? JSONDecoder().decode(SessionFeedback.self, from: data)
    }

    /// 管理画面用: セッションと発話を削除する（cascade）。
    func deleteSession(id: UUID) {
        guard let session = fetchSession(id: id) else { return }
        if activeSession?.id == id {
            activeSession = nil
            activeMessagesByID = [:]
        }
        context.delete(session)
        save()
    }

    // MARK: - private

    private func fetchSessions() -> [ChatSessionRecord] {
        let descriptor = FetchDescriptor<ChatSessionRecord>(
            sortBy: [SortDescriptor(\.startedAt, order: .forward)])
        return (try? context.fetch(descriptor)) ?? []
    }

    private func fetchSession(id: UUID) -> ChatSessionRecord? {
        if let activeSession, activeSession.id == id { return activeSession }
        var descriptor = FetchDescriptor<ChatSessionRecord>(
            predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private func fetchMessage(id: UUID) -> ChatMessageRecord? {
        var descriptor = FetchDescriptor<ChatMessageRecord>(
            predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private func save() {
        do {
            try context.save()
        } catch {
            Self.logger.error("会話履歴の保存に失敗: \(error.localizedDescription)")
        }
    }
}
