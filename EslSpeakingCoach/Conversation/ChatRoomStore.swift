import Foundation
import Observation
import OSLog
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
        /// 日本語訳（未生成は nil）。翻訳トグル ON のとき吹き出しの下に出す
        var translation: String?
    }

    struct UserMessage: Identifiable {
        let id: UUID
        var text: String
        /// 日本語訳（未生成は nil）。STT が何を拾ったかの確認にもなる
        var translation: String?
    }

    /// 吹き出しに出す訳の表示状態（トグル OFF・生成対象外は .hidden）。
    enum TranslationDisplay: Equatable {
        case hidden
        case text(String)
        case loading
        case failed
    }

    /// 翻訳のリクエスト組み立て用に切り出した 1 発話（純粋関数のテストに使う）。
    struct TranslatableMessage: Equatable {
        let id: UUID
        /// 話者ラベル（Chobi / Naruko / Learner）
        let speaker: String
        let text: String
        let translation: String?
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
        /// セッション区切り（表示用の「日付 + トピック名」と、翻訳の文脈に渡すトピック名）
        case sessionDivider(id: UUID, text: String, topic: String)
        case aiMessage(AIMessage)
        case userMessage(UserMessage)
        case topicCard(TopicCard)
        case feedbackCard(FeedbackCard)
        case systemNotice(id: UUID, text: String)

        var id: UUID {
            switch self {
            case .sessionDivider(let id, _, _): return id
            case .aiMessage(let message): return message.id
            case .userMessage(let message): return message.id
            case .topicCard(let card): return card.id
            case .feedbackCard(let card): return card.id
            case .systemNotice(let id, _): return id
            }
        }
    }

    /// アプリ側の固定候補（生成はしない）。
    static let freeTalkCandidate = TopicCandidate(
        title: "フリートーク", hook: "話したいことをそのまま話そう。")

    /// サンプリング時に除外する直近ジャンルの件数（カタログが尽きない範囲に留める）
    static let recentGenreLimit = 8

    private static let inputModeKey = "chatRoomInputMode"
    private static let translationVisibleKey = "chatRoomTranslationVisible"
    /// 1 リクエストで訳す発話数の上限（並列にはせず、このチャンクを順に投げる）
    static let translationChunkSize = 20

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
    /// 訳の表示 ON / OFF（アプリ再起動をまたいで保持する）。
    /// OFF のあいだは翻訳リクエストも投げない
    private(set) var isTranslationVisible: Bool

    /// 会話履歴の永続化（管理画面からも参照する）。
    let historyStore: ChatHistoryStore
    /// AI 利用量の記録（管理画面からも参照する）。
    let usageStore: UsageStore
    /// キャラのセッション横断記憶（管理画面からも参照する）。
    let memoryStore: CharacterMemoryStore

    private static let logger = Logger(
        subsystem: "com.akiraak.EslSpeakingCoach", category: "ChatRoomStore")

    private var session: (any VoiceSession)?
    private var eventTask: Task<Void, Never>?
    /// 手動終了 / goodbye による正常終了か（events 終了時の分岐用）
    private var isEndingSession = false
    private var didAppear = false
    /// 永続化中のセッション ID（正常終了まで保持。エラー再開でも引き継ぐ）
    private var activeSessionID: UUID?
    /// 重複回避用の直近トピックタイトル（起動時に永続化済みセッションから復元。直近 20 件）
    private var recentTopicTitles: [String] = []
    /// 多様性のために避ける直近ジャンル（起動時に復元。カタログが尽きない範囲で 8 件）
    private var recentTopicGenres: [String] = []
    /// 現在セッションの開始時に読み込んだ記憶ノート（エラー再開の rebuildHistory でも同じものを使う）
    private var activeMemoryNote: String?
    /// 翻訳の生成対象（タイムライン末尾のセッション区切り以降の発話 ID）。
    /// 表示はこれより広く、保存済みの訳があればどのセッションの吹き出しでも出す
    private var translationTargetIDs: Set<UUID> = []
    /// 今回のフラッシュで翻訳に失敗した発話（次のフラッシュで再挑戦する）
    private var failedTranslationIDs: Set<UUID> = []
    /// フラッシュの多重実行防止
    private var isFlushingTranslations = false
    #if DEBUG
    private var pendingAutoTexts = DebugLaunchArguments.autoSendTexts
    #endif

    init(container: ModelContainer = AppModelContainer.shared) {
        historyStore = ChatHistoryStore(container: container)
        usageStore = UsageStore(container: container)
        memoryStore = CharacterMemoryStore(container: container)
        let stored = UserDefaults.standard.string(forKey: Self.inputModeKey)
        inputMode = stored.flatMap(InputMode.init(rawValue:)) ?? .voice
        // 既定は OFF（会話中の視界を汚さない）
        isTranslationVisible = UserDefaults.standard.bool(forKey: Self.translationVisibleKey)
    }

    // MARK: - ルームのライフサイクル

    func onAppear() {
        guard !didAppear else { return }
        didAppear = true
        restoreTimeline()
        // 訳 ON のまま再起動した場合、復元した直前セッションの未翻訳分をここで埋める
        scheduleTranslationFlush()
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
        recentTopicGenres = historyStore.recentTopicGenres(limit: Self.recentGenreLimit)
        for record in historyStore.recentSessions(limit: 10) {
            appendItem(.sessionDivider(
                id: UUID(),
                text: "\(Self.dividerDateText(for: record.startedAt)) \(record.topicTitle)",
                topic: record.topicTitle))
            let messages = record.messages.sorted { $0.orderIndex < $1.orderIndex }
            for message in messages {
                guard let speaker = message.speaker else { continue }
                if let character = speaker.character {
                    appendItem(.aiMessage(AIMessage(
                        id: message.id, speaker: character, text: message.text,
                        translation: message.translation)))
                } else {
                    appendItem(.userMessage(UserMessage(
                        id: message.id, text: message.text, translation: message.translation)))
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
                $0.errorText = "Anthropic API キーが未設定です。.secrets/anthropic-api-key を用意して再インストールしてください。"
            }
            return
        }
        // 🔄 のたびに引き直すので、同じカードでもジャンル・話し方の組み合わせが入れ替わる
        var rng = SystemRandomNumberGenerator()
        let assignments = TopicAssignmentSampler.sample(
            excludingGenreIDs: recentTopicGenres, using: &rng)
        do {
            let (topics, usage) = try await TopicSuggestionClient().suggestTopics(
                apiKey: apiKey, recentTitles: recentTopicTitles + extraTitles,
                assignments: assignments)
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
        timelineRevision += 1
    }

    // MARK: - セッション開始・終了

    /// トピックカードの候補選択・自作トピックからセッションを開始する。
    func startSession(topic: String, fromCard cardID: UUID?) {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard session == nil, !trimmed.isEmpty else { return }
        canResumeAfterFailure = false
        // 生成候補から選んだときだけジャンルが分かる（自作トピック・フリートークは nil）
        let genre = cardID
            .flatMap(findCard)?
            .candidates.first { $0.title == trimmed }?
            .genre
            .flatMap { TopicCatalog.genre(id: $0)?.id }
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
        if let genre {
            recentTopicGenres.append(genre)
            if recentTopicGenres.count > Self.recentGenreLimit {
                recentTopicGenres.removeFirst(recentTopicGenres.count - Self.recentGenreLimit)
            }
        }
        appendItem(.sessionDivider(
            id: UUID(), text: "\(Self.dividerDateText(for: Date())) \(trimmed)", topic: trimmed))
        let sessionID = UUID()
        activeSessionID = sessionID
        activeMemoryNote = memoryStore.currentNote()
        historyStore.beginSession(id: sessionID, topicTitle: trimmed, topicGenre: genre)
        launchSession(initialTopic: trimmed, initialHistory: [])
    }

    /// タイムライン下端に固定表示される「このトピックを終了」ボタン（確認アラート経由）。
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
        configuration.memoryNote = activeMemoryNote
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
            activeMemoryNote = nil
            historyStore.endActiveSession()
            // フィードバックカード → 次のトピックカードの順で投稿する（screen-layout.md のセッションの流れ）。
            // フィードバックは生成中表示で即投稿し、完了を待たずに次のトピックを選べるようにする
            if let endedTopic {
                postFeedbackCard(topic: endedTopic, sessionID: endedSessionID)
                updateCharacterMemory(topic: endedTopic, sessionID: endedSessionID)
            }
            // 終了時にも訳を埋めきる（区切りは動いていないので対象は今のセッションのまま）
            scheduleTranslationFlush()
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
                $0.errorText = "Anthropic API キーが未設定です。.secrets/anthropic-api-key を用意して再インストールしてください。"
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

    // MARK: - キャラの記憶

    /// セッション正常終了時に記憶ノートをローリング更新する（docs/plans/character-memory.md）。
    /// フィードバックと同じく学習者の発話 2 未満はスキップ。失敗は best effort
    /// （前回ノートが残るだけで壊れず、次回終了時の生成でカバーされる）。
    private func updateCharacterMemory(topic: String, sessionID: UUID?) {
        let (transcript, learnerTurnCount) = sessionTranscript()
        guard learnerTurnCount >= 2 else { return }
        guard let apiKey = readKey(KeychainStore.anthropicAPIKeyAccount) else { return }
        let previousMemory = memoryStore.currentNote()
        Task {
            do {
                let (memory, usage) = try await MemoryUpdateClient().updateMemory(
                    apiKey: apiKey, previousMemory: previousMemory,
                    topic: topic, transcript: transcript)
                if let usage {
                    usageStore.record(usage, sessionID: sessionID)
                }
                memoryStore.save(text: memory, sourceSessionID: sessionID)
            } catch {
                Self.logger.error("記憶ノートの更新に失敗: \(error.localizedDescription)")
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
            case .userMessage(let message):
                lines.append("Learner: " + message.text)
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
    /// 先頭はセッション開始時と同じ合成メッセージ（[Memory: ...] + [New topic: X]）にする。
    private func rebuildHistory(topic: String) -> [ConversationMessage] {
        var sessionItems: [TimelineItem] = []
        for item in timeline.reversed() {
            if case .sessionDivider = item { break }
            sessionItems.append(item)
        }
        var history = [ConversationMessage(
            role: .user,
            text: SessionOpeningMessage.compose(topic: topic, memoryNote: activeMemoryNote))]
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
            case .userMessage(let message):
                flushScript()
                if let last = history.last, last.role == .user {
                    history[history.count - 1].text += "\n" + message.text
                } else {
                    history.append(ConversationMessage(role: .user, text: message.text))
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

    // MARK: - 会話の翻訳

    /// 翻訳トグル（タイムライン下端）。ON にした時点で対象セッションの未翻訳分をまとめて生成する。
    func setTranslationVisible(_ visible: Bool) {
        guard isTranslationVisible != visible else { return }
        isTranslationVisible = visible
        UserDefaults.standard.set(visible, forKey: Self.translationVisibleKey)
        // 吹き出しが伸び縮みするので自動スクロールを追従させる
        timelineRevision += 1
        scheduleTranslationFlush()
    }

    /// 吹き出しに出す訳の表示状態。保存済みの訳はどのセッションでも出すが、
    /// 「翻訳中…」「翻訳できませんでした」は生成対象セッションの発話にだけ出す。
    func translationDisplay(id: UUID, translation: String?) -> TranslationDisplay {
        guard isTranslationVisible else { return .hidden }
        if let translation, !translation.isEmpty { return .text(translation) }
        guard translationTargetIDs.contains(id) else { return .hidden }
        return failedTranslationIDs.contains(id) ? .failed : .loading
    }

    private func scheduleTranslationFlush() {
        guard isTranslationVisible, !isFlushingTranslations else { return }
        Task { await flushTranslations() }
    }

    /// 生成対象セッションの未翻訳発話を 20 件ずつ順に翻訳して保存する。
    /// 失敗は best effort（次のターン終了・トグル再 ON でもう一度試す）。
    private func flushTranslations() async {
        guard isTranslationVisible, !isFlushingTranslations else { return }
        guard let apiKey = readKey(KeychainStore.anthropicAPIKeyAccount) else { return }
        isFlushingTranslations = true
        defer { isFlushingTranslations = false }
        // 前回の失敗はここで解除し、今回のフラッシュで再挑戦する
        failedTranslationIDs.removeAll()

        let client = TranslationClient()
        while isTranslationVisible {
            let sessionMessages = Self.translationTargetMessages(in: timeline)
            let pending = sessionMessages.filter {
                $0.translation == nil && !failedTranslationIDs.contains($0.id)
            }
            guard !pending.isEmpty else { break }
            let chunk = Array(pending.prefix(Self.translationChunkSize))
            let context = Self.contextLines(
                before: chunk[0].id, in: sessionMessages,
                limit: TranslationClient.contextLineLimit)
            let targets = chunk.map {
                TranslationClient.Item(id: $0.id, speaker: $0.speaker, text: $0.text)
            }
            do {
                let (translations, usage) = try await client.translate(
                    apiKey: apiKey, topic: Self.translationTargetTopic(in: timeline),
                    context: context, targets: targets)
                if let usage {
                    usageStore.record(usage, sessionID: activeSessionID)
                }
                for (id, text) in translations {
                    applyTranslation(id: id, text: text)
                }
                // 返ってこなかった発話は失敗扱いにする（同じチャンクで無限ループしない）
                for item in chunk where translations[item.id] == nil {
                    failedTranslationIDs.insert(item.id)
                }
                timelineRevision += 1
            } catch {
                Self.logger.error("翻訳に失敗: \(error.localizedDescription)")
                for item in chunk {
                    failedTranslationIDs.insert(item.id)
                }
                timelineRevision += 1
                // 通信断などは続けても同じなので、このフラッシュは打ち切る
                break
            }
        }
    }

    private func applyTranslation(id: UUID, text: String) {
        guard let index = timeline.lastIndex(where: { $0.id == id }) else { return }
        switch timeline[index] {
        case .aiMessage(var message):
            message.translation = text
            timeline[index] = .aiMessage(message)
        case .userMessage(var message):
            message.translation = text
            timeline[index] = .userMessage(message)
        default:
            return
        }
        historyStore.updateTranslation(id: id, text: text)
    }

    /// 生成対象セッション（タイムライン末尾の区切り以降）の発話を並び順で切り出す。
    static func translationTargetMessages(in timeline: [TimelineItem]) -> [TranslatableMessage] {
        var reversed: [TranslatableMessage] = []
        for item in timeline.reversed() {
            switch item {
            case .sessionDivider:
                return reversed.reversed()
            case .aiMessage(let message):
                reversed.append(TranslatableMessage(
                    id: message.id, speaker: message.speaker.displayName,
                    text: message.text, translation: message.translation))
            case .userMessage(let message):
                reversed.append(TranslatableMessage(
                    id: message.id, speaker: "Learner",
                    text: message.text, translation: message.translation))
            default:
                break
            }
        }
        // 区切りが 1 つも無い（履歴なしの起動直後など）
        return reversed.reversed()
    }

    /// 生成対象セッションのトピック名（区切りが無ければ nil）。
    static func translationTargetTopic(in timeline: [TimelineItem]) -> String? {
        for item in timeline.reversed() {
            if case .sessionDivider(_, _, let topic) = item { return topic }
        }
        return nil
    }

    /// 対象発話の直前 limit 件を文脈として切り出す（同じセッション内から。足りなければあるだけ）。
    static func contextLines(
        before id: UUID, in messages: [TranslatableMessage], limit: Int
    ) -> [TranslationClient.ContextLine] {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return [] }
        return messages[max(0, index - limit)..<index].map {
            TranslationClient.ContextLine(speaker: $0.speaker, text: $0.text)
        }
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
            if newState == .listening {
                // AI のターンが終わって聞き取りに戻った = 1 ターン確定。
                // 会話のクリティカルパスには載せず、非同期でまとめて訳す
                scheduleTranslationFlush()
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
            appendItem(.userMessage(UserMessage(id: messageID, text: text)))
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
            // 会話練習の邪魔になるのでトーク画面には出さず、管理画面の会話ログにだけ残す
            historyStore.appendLog(kind: .metrics, text: metrics.summaryLine)
        case .micLevel(let level):
            micLevel = level
        case .info(let text):
            // STT 接続・stop_reason などの技術通知も同様に会話ログ行き
            historyStore.appendLog(kind: .notice, text: text)
        case .failure(let text):
            appendItem(.systemNotice(id: UUID(), text: "エラー: \(text)"))
            historyStore.appendLog(kind: .error, text: text)
        }
    }

    private func appendItem(_ item: TimelineItem) {
        // 翻訳の生成対象は「タイムライン末尾のセッション区切り以降」。
        // 区切りが来たら前セッション分を対象から外す（表示は保存済みの訳が残る）
        switch item {
        case .sessionDivider:
            translationTargetIDs.removeAll()
            failedTranslationIDs.removeAll()
        case .aiMessage(let message):
            translationTargetIDs.insert(message.id)
        case .userMessage(let message):
            translationTargetIDs.insert(message.id)
        default:
            break
        }
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

extension TurnMetrics {
    /// 管理画面の会話ログに残す 1 行サマリ（トーク画面には出さない）。
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
