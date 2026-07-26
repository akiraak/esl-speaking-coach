import Foundation
import Observation
import SwiftData
import UIKit

/// 常設グループトークルームの状態（screen-layout.md）。
/// タイムライン・トピックカード・アクティブな会話セッション・入力モードを管理する。
/// トピックごとの会話セッション（VoiceSession）を開始 / 終了しながらタイムラインへ積む。
/// 会話履歴（speaker 付きメッセージ + フィードバック）と AI 利用量は SwiftData に永続化し、
/// 起動時に直近セッションをタイムラインへ復元する。
@MainActor
@Observable
final class ChatRoomStore {
    /// 入力バーのモード。セッション・アプリ再起動をまたいで保持する（UserDefaults）。
    enum InputMode: String {
        case text
        case voice
    }

    struct AIMessage: Identifiable {
        let id: UUID  // = 発話 utteranceID
        let speaker: ChatCharacter
        var text: String
    }

    struct TopicCard: Identifiable {
        let id = UUID()
        var candidates: [TopicCandidate] = []
        var isLoading = false
        var errorText: String?
        /// このカードから選んだトピック（選択済みピルのハイライト用）
        var selectedTitle: String?
        /// 選択済み・過去のカード（グレーアウトしてタップ無効）
        var isUsed = false
    }

    struct FeedbackCard: Identifiable {
        let id = UUID()
        /// 保存先セッション（復元カードでは生成済みのため保存には使わない）
        let sessionID: UUID?
        let topicTitle: String
        /// リトライ用に生成入力（話者ラベル付き会話全文）のスナップショットを保持する
        let transcript: String
        var isLoading = true
        var errorText: String?
        var feedback: SessionFeedback?
    }

    enum TimelineItem: Identifiable {
        /// セッション区切り（日付 + トピック名）
        case sessionDivider(id: UUID, text: String)
        case aiMessage(AIMessage)
        case userMessage(id: UUID, text: String)
        case topicCard(TopicCard)
        case feedbackCard(FeedbackCard)
        case systemNotice(id: UUID, text: String)

        var id: UUID {
            switch self {
            case .sessionDivider(let id, _): return id
            case .aiMessage(let message): return message.id
            case .userMessage(let id, _): return id
            case .topicCard(let card): return card.id
            case .feedbackCard(let card): return card.id
            case .systemNotice(let id, _): return id
            }
        }
    }

    /// アプリ側の固定候補（生成はしない）。
    static let freeTalkCandidate = TopicCandidate(
        title: "フリートーク", hook: "話したいことをそのまま話そう。")

    private static let inputModeKey = "chatRoomInputMode"

    private(set) var timeline: [TimelineItem] = []
    /// タイムラインの追記・伸長のたびに増える（自動スクロールのトリガ。
    /// 発話テキストのストリーミング更新は timeline.count が変わらないため専用カウンタで拾う）
    private(set) var timelineRevision = 0
    private(set) var voiceState: VoiceSessionState = .idle
    private(set) var partialTranscript = ""
    private(set) var micLevel: Float = 0
    /// 読み上げ中の発話（🔊 表示用）
    private(set) var speakingUtteranceID: UUID?
    private(set) var isSessionActive = false
    private(set) var activeTopicTitle: String?
    /// 致命的エラーでセッションが落ちた（履歴を保持したまま再開できる）
    private(set) var canResumeAfterFailure = false
    private(set) var inputMode: InputMode
    /// 音声モードの一時停止（⏸）。聞き取りだけを止める
    private(set) var isVoicePaused = false

    /// 会話履歴の永続化（管理画面からも参照する）。
    let historyStore: ChatHistoryStore
    /// AI 利用量の記録（管理画面からも参照する）。
    let usageStore: UsageStore

    private var session: (any VoiceSession)?
    private var eventTask: Task<Void, Never>?
    /// 手動終了 / goodbye による正常終了か（events 終了時の分岐用）
    private var isEndingSession = false
    private var didAppear = false
    /// 永続化中のセッション ID（正常終了まで保持。エラー再開でも引き継ぐ）
    private var activeSessionID: UUID?
    /// 重複回避用の直近トピックタイトル（起動時に永続化済みセッションから復元。直近 20 件）
    private var recentTopicTitles: [String] = []
    #if DEBUG
    private var pendingAutoTexts = DebugLaunchArguments.autoSendTexts
    #endif

    init(container: ModelContainer = AppModelContainer.shared) {
        historyStore = ChatHistoryStore(container: container)
        usageStore = UsageStore(container: container)
        let stored = UserDefaults.standard.string(forKey: Self.inputModeKey)
        inputMode = stored.flatMap(InputMode.init(rawValue:)) ?? .voice
    }

    var isAnthropicKeyMissing: Bool {
        ((try? KeychainStore().read(account: KeychainStore.anthropicAPIKeyAccount)) ?? nil) == nil
    }

    // MARK: - ルームのライフサイクル

    func onAppear() {
        guard !didAppear else { return }
        didAppear = true
        restoreTimeline()
        postTopicCard()
        #if DEBUG
        if DebugLaunchArguments.shouldStartConversation {
            startSession(topic: Self.freeTalkCandidate.title, fromCard: nil)
        }
        #endif
    }

    /// 起動時に直近セッションをタイムラインへ復元する（全履歴は管理画面で閲覧する）。
    private func restoreTimeline() {
        historyStore.closeUnfinishedSessions()
        recentTopicTitles = historyStore.recentTopicTitles(limit: 20)
        for record in historyStore.recentSessions(limit: 10) {
            appendItem(.sessionDivider(
                id: UUID(),
                text: "\(Self.dividerDateText(for: record.startedAt)) \(record.topicTitle)"))
            let messages = record.messages.sorted { $0.orderIndex < $1.orderIndex }
            for message in messages {
                guard let speaker = message.speaker else { continue }
                if let character = speaker.character {
                    appendItem(.aiMessage(AIMessage(
                        id: message.id, speaker: character, text: message.text)))
                } else {
                    appendItem(.userMessage(id: message.id, text: message.text))
                }
            }
            if let data = record.feedbackJSON,
               let feedback = try? JSONDecoder().decode(SessionFeedback.self, from: data) {
                var card = FeedbackCard(
                    sessionID: record.id, topicTitle: record.topicTitle, transcript: "")
                card.isLoading = false
                card.feedback = feedback
                appendItem(.feedbackCard(card))
            }
        }
    }

    // MARK: - トピックカード

    /// 初回起動時とセッション終了直後に自動投稿する。
    private func postTopicCard() {
        var card = TopicCard()
        card.isLoading = true
        let cardID = card.id
        appendItem(.topicCard(card))
        Task { await fillTopicCard(cardID: cardID, excluding: []) }
    }

    /// 「🔄 他の候補」。表示中の候補も除外リストに加えて同カードを差し替える。
    func regenerateTopics(cardID: UUID) {
        guard let card = findCard(cardID), !card.isUsed, !card.isLoading else { return }
        let shownTitles = card.candidates.map(\.title)
        updateCard(cardID) {
            $0.isLoading = true
            $0.errorText = nil
        }
        Task { await fillTopicCard(cardID: cardID, excluding: shownTitles) }
    }

    private func fillTopicCard(cardID: UUID, excluding extraTitles: [String]) async {
        guard let apiKey = readKey(KeychainStore.anthropicAPIKeyAccount) else {
            updateCard(cardID) {
                $0.isLoading = false
                $0.errorText = "Anthropic API キーが未設定です。設定画面から保存してください。"
            }
            return
        }
        do {
            let (topics, usage) = try await TopicSuggestionClient().suggestTopics(
                apiKey: apiKey, recentTitles: recentTopicTitles + extraTitles)
            if let usage {
                usageStore.record(usage, sessionID: nil)
            }
            updateCard(cardID) {
                $0.isLoading = false
                $0.candidates = topics
                $0.errorText = nil
            }
        } catch {
            updateCard(cardID) {
                $0.isLoading = false
                $0.errorText = "候補の生成に失敗しました: \(error.localizedDescription)"
            }
        }
    }

    private func findCard(_ cardID: UUID) -> TopicCard? {
        for item in timeline.reversed() {
            if case .topicCard(let card) = item, card.id == cardID { return card }
        }
        return nil
    }

    private func updateCard(_ cardID: UUID, _ mutate: (inout TopicCard) -> Void) {
        guard let index = timeline.lastIndex(where: { $0.id == cardID }),
              case .topicCard(var card) = timeline[index] else { return }
        mutate(&card)
        timeline[index] = .topicCard(card)
    }

    // MARK: - セッション開始・終了

    /// トピックカードの候補選択・自作トピックからセッションを開始する。
    func startSession(topic: String, fromCard cardID: UUID?) {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard session == nil, !trimmed.isEmpty else { return }
        canResumeAfterFailure = false
        // 未使用のカードはすべてグレーアウトして履歴に残す（選んだピルのハイライトは該当カードのみ）
        for index in timeline.indices {
            guard case .topicCard(var card) = timeline[index], !card.isUsed else { continue }
            card.isUsed = true
            if card.id == cardID { card.selectedTitle = trimmed }
            timeline[index] = .topicCard(card)
        }
        activeTopicTitle = trimmed
        recentTopicTitles.append(trimmed)
        if recentTopicTitles.count > 20 {
            recentTopicTitles.removeFirst(recentTopicTitles.count - 20)
        }
        appendItem(.sessionDivider(id: UUID(), text: "\(Self.dividerDateText(for: Date())) \(trimmed)"))
        let sessionID = UUID()
        activeSessionID = sessionID
        historyStore.beginSession(id: sessionID, topicTitle: trimmed)
        launchSession(initialTopic: trimmed, initialHistory: [])
    }

    /// ヘッダメニューの「トピックを終える」。
    func endSession() {
        guard let session else { return }
        isEndingSession = true
        session.stop()
    }

    /// 致命的エラー後の再開。タイムラインから会話履歴を組み立てて新しいセッションに引き継ぐ。
    func resumeSessionAfterFailure() {
        guard session == nil, canResumeAfterFailure, let topic = activeTopicTitle else { return }
        canResumeAfterFailure = false
        if let activeSessionID {
            historyStore.resumeSession(id: activeSessionID)
        }
        launchSession(initialTopic: nil, initialHistory: rebuildHistory(topic: topic))
    }

    private func launchSession(initialTopic: String?, initialHistory: [ConversationMessage]) {
        var configuration = TurnBasedVoiceSession.Configuration()
        #if DEBUG
        configuration.ttsProvider = DebugLaunchArguments.ttsProviderOverride ?? .gemini
        #endif
        configuration.initialTopic = initialTopic
        configuration.initialHistory = initialHistory
        configuration.voiceInputEnabled = inputMode == .voice && !isVoicePaused
        let newSession = TurnBasedVoiceSession(
            configuration: configuration,
            claudeKeyProvider: {
                (try? KeychainStore().read(account: KeychainStore.anthropicAPIKeyAccount)) ?? nil
            },
            openAIKeyProvider: {
                (try? KeychainStore().read(account: KeychainStore.openAIAPIKeyAccount)) ?? nil
            },
            geminiKeyProvider: {
                (try? KeychainStore().read(account: KeychainStore.geminiAPIKeyAccount)) ?? nil
            })
        session = newSession
        isSessionActive = true
        // 会話中の放置で画面ロック → バックグラウンド遷移して会話が切れるのを防ぐ
        UIApplication.shared.isIdleTimerDisabled = true
        eventTask = Task { [weak self] in
            for await event in newSession.events {
                self?.handle(event)
            }
            // セッション側が止まった（手動終了 / goodbye / 致命的エラー）
            self?.handleSessionFinished()
        }
        Task { await newSession.start() }
    }

    private func handleSessionFinished() {
        let wasEnding = isEndingSession
        isEndingSession = false
        session = nil
        eventTask = nil
        UIApplication.shared.isIdleTimerDisabled = false
        isSessionActive = false
        voiceState = .idle
        partialTranscript = ""
        micLevel = 0
        speakingUtteranceID = nil
        if wasEnding {
            let endedTopic = activeTopicTitle
            let endedSessionID = activeSessionID
            activeTopicTitle = nil
            activeSessionID = nil
            historyStore.endActiveSession()
            // フィードバックカード → 次のトピックカードの順で投稿する（screen-layout.md のセッションの流れ）。
            // フィードバックは生成中表示で即投稿し、完了を待たずに次のトピックを選べるようにする
            if let endedTopic {
                postFeedbackCard(topic: endedTopic, sessionID: endedSessionID)
            }
            postTopicCard()
        } else {
            // 致命的エラー。タイムラインは残っているので履歴を引き継いで再開できる
            // （永続化セッションも開いたままにし、再開後の発話を追記する）
            canResumeAfterFailure = activeTopicTitle != nil
        }
    }

    // MARK: - フィードバックカード

    /// セッション正常終了（手動 / goodbye）時に投稿する。
    /// 学習者の発話が 2 未満のセッションはスキップする（docs/specs/session-feedback.md）。
    private func postFeedbackCard(topic: String, sessionID: UUID?) {
        let (transcript, learnerTurnCount) = sessionTranscript()
        guard learnerTurnCount >= 2 else {
            appendItem(.systemNotice(id: UUID(), text: "発話が少なかったためフィードバックは省略しました"))
            return
        }
        let card = FeedbackCard(sessionID: sessionID, topicTitle: topic, transcript: transcript)
        let cardID = card.id
        appendItem(.feedbackCard(card))
        Task { await fillFeedbackCard(cardID: cardID) }
    }

    /// 生成失敗時のリトライ（カード内ボタンから）。
    func retryFeedback(cardID: UUID) {
        guard let card = findFeedbackCard(cardID), !card.isLoading, card.feedback == nil else { return }
        updateFeedbackCard(cardID) {
            $0.isLoading = true
            $0.errorText = nil
        }
        Task { await fillFeedbackCard(cardID: cardID) }
    }

    private func fillFeedbackCard(cardID: UUID) async {
        guard let card = findFeedbackCard(cardID) else { return }
        guard let apiKey = readKey(KeychainStore.anthropicAPIKeyAccount) else {
            updateFeedbackCard(cardID) {
                $0.isLoading = false
                $0.errorText = "Anthropic API キーが未設定です。設定画面から保存してください。"
            }
            return
        }
        do {
            let (feedback, usage) = try await SessionFeedbackClient().generateFeedback(
                apiKey: apiKey, topic: card.topicTitle, transcript: card.transcript)
            if let usage {
                usageStore.record(usage, sessionID: card.sessionID)
            }
            if let sessionID = card.sessionID {
                historyStore.saveFeedback(sessionID: sessionID, feedback: feedback)
            }
            updateFeedbackCard(cardID) {
                $0.isLoading = false
                $0.feedback = feedback
                $0.errorText = nil
            }
        } catch {
            updateFeedbackCard(cardID) {
                $0.isLoading = false
                $0.errorText = "フィードバックの生成に失敗しました: \(error.localizedDescription)"
            }
        }
    }

    private func findFeedbackCard(_ cardID: UUID) -> FeedbackCard? {
        for item in timeline.reversed() {
            if case .feedbackCard(let card) = item, card.id == cardID { return card }
        }
        return nil
    }

    private func updateFeedbackCard(_ cardID: UUID, _ mutate: (inout FeedbackCard) -> Void) {
        guard let index = timeline.lastIndex(where: { $0.id == cardID }),
              case .feedbackCard(var card) = timeline[index] else { return }
        mutate(&card)
        timeline[index] = .feedbackCard(card)
        timelineRevision += 1
    }

    /// 現在セッション区間（最後の区切り以降）の話者ラベル付きトランスクリプトと学習者の発話数。
    private func sessionTranscript() -> (transcript: String, learnerTurnCount: Int) {
        var sessionItems: [TimelineItem] = []
        for item in timeline.reversed() {
            if case .sessionDivider = item { break }
            sessionItems.append(item)
        }
        var lines: [String] = []
        var learnerTurnCount = 0
        for item in sessionItems.reversed() {
            switch item {
            case .userMessage(_, let text):
                lines.append("Learner: " + text)
                learnerTurnCount += 1
            case .aiMessage(let message):
                lines.append(message.speaker.displayName + ": " + message.text)
            default:
                break
            }
        }
        return (lines.joined(separator: "\n"), learnerTurnCount)
    }

    /// タイムラインの現在セッション区間（最後の区切り以降）から API 用の会話履歴を組み立てる。
    /// 連続する AI 発話は 1 つのタグ付き台本メッセージへ再直列化する。
    private func rebuildHistory(topic: String) -> [ConversationMessage] {
        var sessionItems: [TimelineItem] = []
        for item in timeline.reversed() {
            if case .sessionDivider = item { break }
            sessionItems.append(item)
        }
        var history = [ConversationMessage(role: .user, text: "[New topic: \(topic)]")]
        var pendingScript: [String] = []
        func flushScript() {
            guard !pendingScript.isEmpty else { return }
            history.append(ConversationMessage(
                role: .assistant, text: pendingScript.joined(separator: "\n")))
            pendingScript = []
        }
        for item in sessionItems.reversed() {
            switch item {
            case .aiMessage(let message):
                pendingScript.append(message.speaker.scriptTag + message.text)
            case .userMessage(_, let text):
                flushScript()
                if let last = history.last, last.role == .user {
                    history[history.count - 1].text += "\n" + text
                } else {
                    history.append(ConversationMessage(role: .user, text: text))
                }
            default:
                break
            }
        }
        flushScript()
        return history
    }

    // MARK: - 入力

    func sendText(_ text: String) {
        session?.submitTypedUserTurn(text)
    }

    func setInputMode(_ mode: InputMode) {
        guard inputMode != mode else { return }
        inputMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.inputModeKey)
        if mode == .voice { isVoicePaused = false }
        session?.setVoiceInputEnabled(mode == .voice)
    }

    /// 音声モードの ⏸ / 再開。
    func toggleVoicePause() {
        guard inputMode == .voice else { return }
        isVoicePaused.toggle()
        session?.setVoiceInputEnabled(!isVoicePaused)
    }

    // MARK: - セッションイベント

    private func handle(_ event: VoiceSessionEvent) {
        switch event {
        case .stateChanged(let newState):
            voiceState = newState
            if newState != .listening {
                partialTranscript = ""
            }
            if newState != .speaking {
                speakingUtteranceID = nil
            }
            #if DEBUG
            if newState == .listening, !pendingAutoTexts.isEmpty {
                sendText(pendingAutoTexts.removeFirst())
            }
            #endif
        case .userPartialTranscript(let text):
            partialTranscript = text
        case .userTurnCommitted(let text):
            partialTranscript = ""
            let messageID = UUID()
            appendItem(.userMessage(id: messageID, text: text))
            historyStore.appendMessage(id: messageID, speaker: .user, text: text)
        case .assistantUtteranceBegan(let id, let speaker, let text):
            appendItem(.aiMessage(AIMessage(id: id, speaker: speaker, text: text)))
            historyStore.appendMessage(id: id, speaker: MessageSpeaker(character: speaker), text: text)
            speakingUtteranceID = id
        case .assistantUtteranceUpdated(let id, let text):
            if let index = timeline.lastIndex(where: { $0.id == id }),
               case .aiMessage(var message) = timeline[index] {
                message.text = text
                timeline[index] = .aiMessage(message)
                timelineRevision += 1
            }
            historyStore.updateMessageText(id: id, text: text)
        case .apiUsage(let usage):
            usageStore.record(usage, sessionID: activeSessionID)
        case .sessionEndDetected:
            // goodbye 自動終了。手動終了と同じ導線でセッションを閉じる
            isEndingSession = true
            session?.stop()
        case .turnMetrics(let metrics):
            #if DEBUG
            appendItem(.systemNotice(id: UUID(), text: metrics.summaryLine))
            #endif
            _ = metrics
        case .micLevel(let level):
            micLevel = level
        case .info(let text):
            appendItem(.systemNotice(id: UUID(), text: text))
        case .failure(let text):
            appendItem(.systemNotice(id: UUID(), text: "エラー: \(text)"))
        }
    }

    private func appendItem(_ item: TimelineItem) {
        timeline.append(item)
        timelineRevision += 1
    }

    private func readKey(_ account: String) -> String? {
        (try? KeychainStore().read(account: account)) ?? nil
    }

    private static func dividerDateText(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }
}

#if DEBUG
extension TurnMetrics {
    /// DEBUG ビルドの参考表示用 1 行サマリ（製品画面には出さない）。
    var summaryLine: String {
        func fmt(_ value: Double?) -> String {
            guard let value else { return "-" }
            return String(format: "%.0f", value)
        }
        return "体感 \(fmt(perceivedTotalMs))ms | 無音待ち \(fmt(endpointWaitMs)) | "
            + "STT確定 \(fmt(sttFinalizeMs)) | TTFT \(fmt(ttftMs)) | "
            + "初文 \(fmt(firstSentenceMs)) | 発声 \(fmt(speakStartMs))"
    }
}
#endif
