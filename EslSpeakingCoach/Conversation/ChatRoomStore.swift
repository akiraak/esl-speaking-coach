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
        /// 投稿時の練習モード。単語モードのカードは生成候補も 🔄 も持たず、
        /// 前に練習した語のピル（`wordSuggestions`）と練習・クイズの開始ボタンを出す
        var mode: PracticeMode = .conversation
        var candidates: [TopicCandidate] = []
        /// 単語モードのカードに出す「前に練習した語」（新しい順・重複除去済み）。
        /// 生成はせず履歴から引くだけなので、投稿時に確定して以後は変わらない
        var wordSuggestions: [String] = []
        /// 単語モードのカードのクイズ導線が使う出題母集団（練習済みの語）の数。
        /// 履歴から引くだけなので投稿時に確定。0 ならクイズボタンを無効化する
        var quizPoolCount = 0
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
        /// そのセッションの種別（生成の見出しを `Topic:` / `Practice word:` で出し分ける。
        /// リトライがモード切替後になっても開始時の種別で生成するようカードに持たせる）
        var kind: SessionKind = .conversation
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
    /// これを選んだセッションだけ AI の開始ターンを出さず、最初のターンを学習者から始める
    /// （docs/plans/learner-first-topic.md）。
    static let talkFirstCandidate = TopicCandidate(
        title: "話しかける", hook: "自分から話しかけてみよう。")

    /// 学習者から始めるトピックか（固定候補と同じタイトルの自作トピックも同じ扱いにする）。
    static func isLearnerFirstTopic(_ title: String) -> Bool {
        title == talkFirstCandidate.title
    }

    /// サンプリング時に除外する直近ジャンルの件数（カタログが尽きない範囲に留める）
    static let recentGenreLimit = 8

    /// トピックカードに出す生成候補の件数（別枠の固定候補「話しかける」は含まない）
    static let topicCandidateCount = 3

    /// 単語カードに出す「前に練習した語」の件数（多すぎるとカードが縦に伸びる）
    static let wordSuggestionCount = 6
    /// 重複を畳む前に履歴から読む単語セッションの件数（同じ語を繰り返し練習しても上限まで埋まるよう多めに取る）
    static let wordSuggestionScanLimit = 40
    /// 1 回のクイズで出題する語数（1 セッション 1 語で気軽に受けられるテンポにする。
    /// 増やしたくなったらこの定数を戻す）
    static let quizWordCount = 1

    private static let inputModeKey = "chatRoomInputMode"
    private static let practiceModeKey = "chatRoomPracticeMode"
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
    /// 練習モード（会話 / 単語）。アプリ再起動をまたいで保持する（UserDefaults）。
    /// セッション中は切り替えない（途中でキャラの役割が変わると会話が破綻するため）
    private(set) var practiceMode: PracticeMode
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
    /// 現在セッションを始めたときのセッション種別（終了処理の分岐と、終了ボタン・確認アラートの
    /// 文言に使う。セッション終了後は前セッションの値が残るが、そのときボタンもアラートも出ない）
    private(set) var activeSessionKind: SessionKind = .conversation
    /// 重複回避用の直近トピックタイトル（起動時に永続化済みセッションから復元。直近 20 件）
    private var recentTopicTitles: [String] = []
    /// 多様性のために避ける直近ジャンル（起動時に復元。カタログが尽きない範囲で 8 件）
    private var recentTopicGenres: [String] = []
    /// 次のトピックカードへ持ち越す候補（今回のセッションで選ばなかったぶん）。
    /// メモリ上のみ = 再起動したら持ち越し無しで 3 件生成に戻る
    private var carryOverCandidates: [TopicCandidate] = []
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
    /// -start-from-card は最初のカードでだけ発火させる
    private var didAutoStartFromCard = false
    /// -start-quiz は最初の単語カードでだけ発火させる
    private var didAutoStartQuiz = false
    /// -end-session は最初のセッションでだけ発火させる
    private var didAutoEndSession = false
    /// AI の開始ターンを待っているあいだは -send-text を送らない
    /// （STT 接続直後の listening で送ると開始ターンを barge-in で潰してしまう）
    private var awaitsOpeningTurn = false
    #endif

    init(container: ModelContainer = AppModelContainer.shared) {
        historyStore = ChatHistoryStore(container: container)
        usageStore = UsageStore(container: container)
        memoryStore = CharacterMemoryStore(container: container)
        let stored = UserDefaults.standard.string(forKey: Self.inputModeKey)
        inputMode = stored.flatMap(InputMode.init(rawValue:)) ?? .voice
        // 既定は会話モード（旧バージョンの quiz は init(storedValue:) が単語モードへ正規化する）
        practiceMode = PracticeMode(
            storedValue: UserDefaults.standard.string(forKey: Self.practiceModeKey))
        #if DEBUG
        // シミュレータ確認用の上書き（保存はしない）
        if let override = DebugLaunchArguments.practiceModeOverride {
            practiceMode = override
        }
        #endif
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
        if let word = DebugLaunchArguments.startWord {
            startSession(topic: word, fromCard: nil)
        } else if DebugLaunchArguments.shouldStartConversation {
            startSession(topic: Self.talkFirstCandidate.title, fromCard: nil)
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
                text: Self.dividerText(
                    kind: record.kind, title: record.topicTitle, date: record.startedAt),
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
                    sessionID: record.id, kind: record.kind,
                    topicTitle: record.topicTitle, transcript: "")
                card.isLoading = false
                card.feedback = feedback
                appendItem(.feedbackCard(card))
            }
        }
    }

    // MARK: - トピックカード

    /// 初回起動時・セッション終了直後・モード切替時に自動投稿する。
    /// 直前のセッションを始めたカードの未使用候補は持ち越し、生成は補充ぶんの 1 件だけにする
    /// （docs/plans/topic-card-carry-over.md）。持ち越しが無ければ従来どおり 3 件生成する。
    /// 単語モードでは候補を生成しない（練習語はユーザーが入力する）ので、練習の導線
    /// （入力 / 単語帳 / ランダム）とクイズの開始ボタンを持つカードを出す
    /// （出題語はカードに出さない。始まる前に見えたらクイズにならない）。
    private func postTopicCard() {
        switch practiceMode {
        case .word:
            var card = TopicCard(mode: .word)
            card.wordSuggestions = Self.practicedWordSuggestions(
                from: historyStore.recentWords(limit: Self.wordSuggestionScanLimit))
            card.quizPoolCount = Self.quizPool(
                from: historyStore.recentWords(limit: Int.max)).count
            let wordCardID = card.id
            appendItem(.topicCard(card))
            #if DEBUG
            // -start-from-card は単語カードでは「前に練習した語」の 1 件目をタップした扱いにする
            // （ピルからの再練習を E2E で通すため。最初の 1 枚だけ）
            if DebugLaunchArguments.shouldStartFromTopicCard, !didAutoStartFromCard,
               session == nil, let word = card.wordSuggestions.first {
                didAutoStartFromCard = true
                startSession(topic: word, fromCard: wordCardID)
            }
            // -start-quiz は単語カードのクイズボタンをタップした扱いにする（最初の 1 枚だけ）
            if DebugLaunchArguments.shouldStartQuiz, !didAutoStartQuiz,
               session == nil, card.quizPoolCount > 0 {
                didAutoStartQuiz = true
                startQuizSession(fromCard: wordCardID)
            }
            #endif
        case .conversation:
            var card = TopicCard()
            card.candidates = carryOverCandidates
            card.isLoading = true
            let cardID = card.id
            let carried = carryOverCandidates
            carryOverCandidates = []
            appendItem(.topicCard(card))
            Task { await fillTopicCard(cardID: cardID, carryOver: carried) }
        }
    }

    /// 「🔄 他の候補」。表示中の候補も除外リストに加えて全件を差し替える。
    func regenerateTopics(cardID: UUID) {
        guard let card = findCard(cardID), card.mode == .conversation,
              !card.isUsed, !card.isLoading else { return }
        let shownTitles = card.candidates.map(\.title)
        updateCard(cardID) {
            $0.isLoading = true
            $0.errorText = nil
        }
        Task {
            await fillTopicCard(cardID: cardID, carryOver: [], excludingTitles: shownTitles)
        }
    }

    /// カードの候補を埋める。carryOver があるぶんだけ生成件数を減らし、後ろに足す。
    private func fillTopicCard(
        cardID: UUID, carryOver: [TopicCandidate], excludingTitles extraTitles: [String] = []
    ) async {
        let missing = max(0, Self.topicCandidateCount - carryOver.count)
        guard missing > 0 else {
            updateCard(cardID) { $0.isLoading = false }
            return
        }
        guard let apiKey = readKey(KeychainStore.anthropicAPIKeyAccount) else {
            updateCard(cardID) {
                $0.isLoading = false
                $0.errorText = "Anthropic API キーが未設定です。.secrets/anthropic-api-key を用意して再インストールしてください。"
            }
            return
        }
        // 🔄 のたびに引き直すので、同じカードでもジャンル・話し方の組み合わせが入れ替わる。
        // 持ち越しと同じジャンルが並ばないよう、その genre も除外に足す
        var rng = SystemRandomNumberGenerator()
        let assignments = TopicAssignmentSampler.sample(
            count: missing,
            excludingGenreIDs: recentTopicGenres + carryOver.compactMap(\.genre),
            using: &rng)
        do {
            let (topics, usage) = try await TopicSuggestionClient().suggestTopics(
                apiKey: apiKey,
                recentTitles: recentTopicTitles + extraTitles + carryOver.map(\.title),
                assignments: assignments)
            if let usage {
                usageStore.record(usage, sessionID: nil)
            }
            updateCard(cardID) {
                $0.isLoading = false
                // 生成を待つ間に持ち越し候補が選ばれていたら、そのカードには足さない
                guard !$0.isUsed else { return }
                $0.candidates = Self.mergedCandidates(carryOver: carryOver, generated: topics)
                $0.errorText = nil
            }
            #if DEBUG
            // 最初の 1 枚だけ（終了後のカードまで自動で始めると持ち越しの確認ができない）
            if DebugLaunchArguments.shouldStartFromTopicCard, !didAutoStartFromCard,
               session == nil, let candidate = findCard(cardID)?.candidates.first {
                didAutoStartFromCard = true
                startSession(topic: candidate.title, fromCard: cardID)
            }
            #endif
        } catch {
            updateCard(cardID) {
                // 生成に失敗しても持ち越しは残す（カードが空にならない）
                $0.isLoading = false
                guard !$0.isUsed else { return }
                $0.errorText = "候補の生成に失敗しました: \(error.localizedDescription)"
            }
        }
    }

    /// 持ち越しの後ろに生成ぶんを足す（タイトル重複は落とし、上限 `topicCandidateCount` まで）。
    static func mergedCandidates(
        carryOver: [TopicCandidate], generated: [TopicCandidate]
    ) -> [TopicCandidate] {
        var merged = carryOver
        var seen = Set(carryOver.map(\.title))
        for candidate in generated where !seen.contains(candidate.title) {
            merged.append(candidate)
            seen.insert(candidate.title)
        }
        return Array(merged.prefix(topicCandidateCount))
    }

    /// セッション開始で消費されなかった候補（= 次のカードへ持ち越すぶん）。
    /// 自作トピック・固定候補では何も消費されないので先頭から詰める。
    /// 常に「持ち越し + 生成 1 件」の形にするため `topicCandidateCount - 1` 件までに切る。
    static func carryOverCandidates(
        from card: TopicCard?, selectedTitle: String
    ) -> [TopicCandidate] {
        guard let card else { return [] }
        let remaining = card.candidates.filter { $0.title != selectedTitle }
        return Array(remaining.prefix(topicCandidateCount - 1))
    }

    /// 単語カードに出す「前に練習した語」（純関数）。
    /// 入力は新しい順の練習語（`ChatHistoryStore.recentWords`）、出力は表示するピル。
    /// 同じ語を何度練習しても履歴には都度残るので、正規化キーで畳んで**新しい方の表記**だけを残す。
    static func practicedWordSuggestions(
        from recentWords: [String], limit: Int = wordSuggestionCount
    ) -> [String] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        var suggestions: [String] = []
        for word in recentWords {
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = normalizedWordKey(trimmed)
            guard seen.insert(key).inserted else { continue }
            suggestions.append(trimmed)
            if suggestions.count >= limit { break }
        }
        return suggestions
    }

    /// 練習語の重複判定キー（小文字化 + 前後空白の除去 + 連続空白の畳み込み）。
    /// 表記ゆれ（"Get around to" / "get  around to"）を同じ語として扱う。
    static func normalizedWordKey(_ word: String) -> String {
        word.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// ランダム出題: 単語帳から練習済みの語を除く（純関数。docs/plans/wordbook-random-word.md）。
    /// 照合は `normalizedWordKey`（単語帳側は正規化済みなのでこのキーで足りる）。
    static func unpracticedWords(
        all: [WordBookEntry], practiced: [String]
    ) -> [WordBookEntry] {
        let practicedKeys = Set(practiced.map(normalizedWordKey))
        return all.filter { !practicedKeys.contains(normalizedWordKey($0.word)) }
    }

    /// 単語カードに出す単語帳の集計（純関数。docs/plans/word-card-counts.md）。
    /// 「未練習」の定義はランダム出題と同一（`unpracticedWords`）に保ち、
    /// 表示する数字と「ランダムに選ぶ」の母集団を一致させる。
    static func wordBookTally(
        all: [WordBookEntry], practiced: [String]
    ) -> (total: Int, unpracticed: Int) {
        (all.count, unpracticedWords(all: all, practiced: practiced).count)
    }

    /// 集計の表示文言（例: `練習済み 42/185語 22%・未練習 143語`）。
    /// パーセントは切り捨て（四捨五入だと未練習が残っているのに 100% に見える瞬間ができる。
    /// 切り捨てなら 100% = 全語練習済みが常に成り立つ）。総数 0 のときは nil で行ごと非表示。
    static func wordBookTallyLabel(total: Int, unpracticed: Int) -> String? {
        guard total > 0 else { return nil }
        let practiced = total - unpracticed
        return "練習済み \(practiced)/\(total)語 \(practiced * 100 / total)%・未練習 \(unpracticed)語"
    }

    /// ランダム出題ボタンの文言（docs/plans/random-word-button-label.md）。
    /// 母集団（未練習）を明示し、全語練習済みのときは全語フォールバック
    /// （`randomWordChoice`）の実挙動に文言を合わせる。集計が取れていないとき（nil =
    /// シークレット未設定・取得失敗・使用済みカード）は母集団を断言しない従来文言に留める。
    static func randomWordButtonTitle(unpracticed: Int?) -> String {
        switch unpracticed {
        case nil: return "ランダムに選ぶ"
        case 0: return "全語からランダムに選ぶ"
        default: return "未練習からランダムに選ぶ"
        }
    }

    /// 単語カードのクイズボタンの文言。出題数（`quizWordCount`）を変えても
    /// 文言が古くならないよう定数から組み立てる（docs/plans/archive/quiz-in-word-mode.md）。
    static var quizButtonTitle: String {
        "練習済みからクイズ（\(quizWordCount)語）"
    }

    /// ランダム出題で選ぶ語（純関数）。未練習の語から選び、全語練習済みなら
    /// 全語へフォールバックする（isFallback = true。再練習にも価値があり、
    /// ボタンが「何も起きない」体験を避ける）。単語帳が空のときだけ nil。
    static func randomWordChoice<R: RandomNumberGenerator>(
        unpracticed: [WordBookEntry], all: [WordBookEntry], using rng: inout R
    ) -> (entry: WordBookEntry, isFallback: Bool)? {
        if let entry = unpracticed.randomElement(using: &rng) {
            return (entry, false)
        }
        guard let entry = all.randomElement(using: &rng) else { return nil }
        return (entry, true)
    }

    // MARK: - 単語クイズ（docs/plans/word-quiz-mode.md）

    /// クイズの出題母集団（純関数）。入力は新しい順の練習語（`ChatHistoryStore.recentWords`）、
    /// 出力は正規化キーで畳んで新しい表記を残した練習済みの語の全件
    /// （単語カードのピル `practicedWordSuggestions` と同じ定義の上限なし版）。
    static func quizPool(from recentWords: [String]) -> [String] {
        practicedWordSuggestions(from: recentWords, limit: Int.max)
    }

    /// 出題済みの語の復元（純関数）。クイズセッションの `topicTitle`（`", "` 連結）を
    /// 分割して語に戻す。語自体にカンマを含むと壊れるが、実際の練習語ではまず無いので許容する。
    static func quizzedWords(fromTitles titles: [String]) -> [String] {
        titles.flatMap { title in
            title.components(separatedBy: ", ")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
    }

    /// 未出題の語（純関数）: 母集団から出題済みを正規化キーで除いた残り。
    /// 「未練習」（`unpracticedWords`）と同じ手筋で、選択と診断ログの数字を一致させる。
    static func unquizzedWords(pool: [String], quizzed: [String]) -> [String] {
        let quizzedKeys = Set(quizzed.map(normalizedWordKey))
        return pool.filter { !quizzedKeys.contains(normalizedWordKey($0)) }
    }

    /// クイズの出題語（純関数）。未出題からランダムに count 語選び、満たなければ出題済みから
    /// 補充する（クイズの長さを揃える）。全語出題済みなら全語からのフォールバック、
    /// 母集団が count 未満なら全語。出題順もここで確定する（プロンプトはこの順に出題する）。
    static func quizWords<R: RandomNumberGenerator>(
        pool: [String], quizzed: [String], count: Int, using rng: inout R
    ) -> [String] {
        guard count > 0 else { return [] }
        let unquizzed = unquizzedWords(pool: pool, quizzed: quizzed)
        var words = Array(unquizzed.shuffled(using: &rng).prefix(count))
        if words.count < count {
            let unquizzedKeys = Set(unquizzed.map(normalizedWordKey))
            let alreadyQuizzed = pool.filter { !unquizzedKeys.contains(normalizedWordKey($0)) }
            words += alreadyQuizzed.shuffled(using: &rng).prefix(count - words.count)
        }
        return words
    }

    /// 単語カードの「練習済みからクイズ」。練習済みの語から未出題を優先して最大 `quizWordCount`
    /// 語を選び、`", "` 連結をトピックとして kind = .quiz のセッション開始へ流す（ネットワーク不要）。
    /// 連結文字列がそのまま `[Quiz words: ...]` の制御メッセージと `topicTitle` になる。
    func startQuizSession(fromCard cardID: UUID?) {
        guard session == nil, practiceMode == .word else { return }
        let pool = Self.quizPool(from: historyStore.recentWords(limit: Int.max))
        let quizzed = Self.quizzedWords(fromTitles: historyStore.quizzedTitlesAll())
        let unquizzedCount = Self.unquizzedWords(pool: pool, quizzed: quizzed).count
        var rng = SystemRandomNumberGenerator()
        let words = Self.quizWords(
            pool: pool, quizzed: quizzed, count: Self.quizWordCount, using: &rng)
        guard !words.isEmpty else { return }
        DiagnosticsLog.record(
            "quiz: 母集団\(pool.count)語 未出題\(unquizzedCount)語 → \(words.joined(separator: ", "))"
            + (unquizzedCount == 0 ? "（全語出題済みのため全語から選択）" : ""))
        startSession(topic: words.joined(separator: ", "), fromCard: cardID, kind: .quiz)
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
    /// セッションの種別は UI の練習モードと独立に指定できる（既定は UI モードと同名の種別）――
    /// クイズは UI モード = word のまま kind = .quiz で開始する（docs/plans/archive/quiz-in-word-mode.md）。
    func startSession(topic: String, fromCard cardID: UUID?, kind: SessionKind? = nil) {
        let kind = kind ?? practiceMode.defaultSessionKind
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard session == nil, !trimmed.isEmpty else { return }
        canResumeAfterFailure = false
        // 生成候補から選んだときだけジャンルが分かる（自作トピック・固定候補は nil）
        let genre = cardID
            .flatMap(findCard)?
            .candidates.first { $0.title == trimmed }?
            .genre
            .flatMap { TopicCatalog.genre(id: $0)?.id }
        // 選ばなかった候補は次のカードへ持ち越す（生成は補充の 1 件だけで済む）。
        // 単語モードのカードには候補が無いので触らない（会話モードで戻した持ち越しを消さない）
        if kind == .conversation {
            carryOverCandidates = Self.carryOverCandidates(
                from: cardID.flatMap(findCard), selectedTitle: trimmed)
        }
        // 未使用のカードはすべてグレーアウトして履歴に残す（選んだピルのハイライトは該当カードのみ）。
        // クイズ開始では selectedTitle を設定しない ―― 単語カードは selectedTitle を
        // 語のピルとして表示するため、設定すると出題語がチャット欄に見えてしまう
        for index in timeline.indices {
            guard case .topicCard(var card) = timeline[index], !card.isUsed else { continue }
            card.isUsed = true
            if card.id == cardID, kind != .quiz { card.selectedTitle = trimmed }
            timeline[index] = .topicCard(card)
        }
        activeTopicTitle = trimmed
        // 重複回避リストはトピック生成用なので練習語は混ぜない
        // （起動時の復元でも単語モードのセッションは除外している）
        if kind == .conversation {
            recentTopicTitles.append(trimmed)
            if recentTopicTitles.count > 20 {
                recentTopicTitles.removeFirst(recentTopicTitles.count - 20)
            }
        }
        if let genre {
            recentTopicGenres.append(genre)
            if recentTopicGenres.count > Self.recentGenreLimit {
                recentTopicGenres.removeFirst(recentTopicGenres.count - Self.recentGenreLimit)
            }
        }
        appendItem(.sessionDivider(
            id: UUID(),
            text: Self.dividerText(kind: kind, title: trimmed, date: Date()),
            topic: trimmed))
        let sessionID = UUID()
        activeSessionID = sessionID
        activeSessionKind = kind
        // 単語・クイズでは記憶ノートを注入しない（終了時の更新もしないので対称）
        activeMemoryNote = kind.usesMemoryNote ? memoryStore.currentNote() : nil
        historyStore.beginSession(
            id: sessionID, topicTitle: trimmed, topicGenre: genre, kind: kind)
        // 単語・クイズは常に Chobi の導入ターンから始める（学習者ファーストは使わない）
        if kind == .conversation, Self.isLearnerFirstTopic(trimmed) {
            // AI が黙ったまま listening になるので、待ち受けであることを 1 行だけ伝える
            appendItem(.systemNotice(id: UUID(), text: "自分から話しかけてみよう"))
            launchSession(opening: .learnerFirst, initialHistory: [])
        } else {
            launchSession(opening: .assistantFirst(topic: trimmed), initialHistory: [])
        }
    }

    /// タイムライン下端に固定表示される「このトピックを終了」ボタン（確認アラート経由）。
    func endSession() {
        guard let session else {
            DiagnosticsLog.record("end: ボタン押下（セッション無し・何もしない）")
            return
        }
        // 落ちたときにどの状況で押したかを特定するための足跡（docs/plans/end-session-crash.md）
        DiagnosticsLog.record(
            "end: ボタン押下 state=\(voiceState) mode=\(inputMode.rawValue) "
            + "paused=\(isVoicePaused) 学習者発話=\(sessionTranscript().learnerTurnCount) "
            + "translation=\(isTranslationVisible)")
        isEndingSession = true
        session.stop()
        DiagnosticsLog.record("end: session.stop() から復帰")
    }

    /// 致命的エラー後の再開。タイムラインから会話履歴を組み立てて新しいセッションに引き継ぐ。
    func resumeSessionAfterFailure() {
        guard session == nil, canResumeAfterFailure, let topic = activeTopicTitle else { return }
        canResumeAfterFailure = false
        if let activeSessionID {
            historyStore.resumeSession(id: activeSessionID)
        }
        launchSession(opening: .resume, initialHistory: rebuildHistory(topic: topic))
    }

    private func launchSession(
        opening: TurnBasedVoiceSession.Opening,
        initialHistory: [ConversationMessage]
    ) {
        var configuration = TurnBasedVoiceSession.Configuration()
        #if DEBUG
        configuration.ttsProvider = DebugLaunchArguments.ttsProviderOverride ?? .gemini
        if let sttModel = DebugLaunchArguments.sttModelOverride {
            configuration.transcription.model = sttModel
        }
        if let sttDelay = DebugLaunchArguments.sttDelayOverride {
            configuration.transcription.delay = sttDelay
        }
        // Qwen TTS の voice はリビルドせずに聞き比べられるよう起動引数で差し替え可
        // （SpeechStyle.voice は Gemini の voice 名で届くため、そのキーで写像を上書きする）
        if let chobiVoice = DebugLaunchArguments.qwenVoiceChobiOverride {
            configuration.qwenTTS.voiceMap[ChatCharacter.chobi.speechStyle.voice] = chobiVoice
        }
        if let narukoVoice = DebugLaunchArguments.qwenVoiceNarukoOverride {
            configuration.qwenTTS.voiceMap[ChatCharacter.naruko.speechStyle.voice] = narukoVoice
        }
        // AI から始まるセッションでは、開始ターンの最初の発話が出るまで -send-text を止める
        if case .assistantFirst = opening { awaitsOpeningTurn = true }
        #endif
        configuration.opening = opening
        // UI の練習モードではなくセッションの種別（クイズ中は word / quiz と食い違う）
        configuration.sessionKind = activeSessionKind
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
            },
            dashScopeKeyProvider: {
                (try? KeychainStore().read(account: KeychainStore.dashScopeAPIKeyAccount)) ?? nil
            })
        DiagnosticsLog.record(
            "session: 開始 topic=\(activeTopicTitle ?? "-") opening=\(opening) "
            + "practice=\(activeSessionKind.rawValue) "
            + "mode=\(inputMode.rawValue) 再開=\(initialHistory.isEmpty ? "no" : "yes")")
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
        DiagnosticsLog.record("end: セッション終了を検知 wasEnding=\(wasEnding)")
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
            let endedKind = activeSessionKind
            activeTopicTitle = nil
            activeSessionID = nil
            activeMemoryNote = nil
            historyStore.endActiveSession()
            DiagnosticsLog.record("end: 履歴セッションを閉じた session=\(endedSessionID?.uuidString ?? "-")")
            // フィードバックカード → 次のトピックカードの順で投稿する（screen-layout.md のセッションの流れ）。
            // フィードバックは生成中表示で即投稿し、完了を待たずに次のトピックを選べるようにする
            if let endedTopic {
                postFeedbackCard(kind: endedKind, topic: endedTopic, sessionID: endedSessionID)
                DiagnosticsLog.record("end: フィードバックカード投稿まで完了")
                // 単語・クイズは記憶ノートを更新しない（注入もしないので対称）。
                // 単語練習の逐語がノートに入ると会話モードの雑談品質が落ちるため
                if endedKind.usesMemoryNote {
                    updateCharacterMemory(topic: endedTopic, sessionID: endedSessionID)
                } else {
                    DiagnosticsLog.record("memory: 単語モードのため記憶ノートの更新をスキップ")
                }
            }
            // 終了時にも訳を埋めきる（区切りは動いていないので対象は今のセッションのまま）
            scheduleTranslationFlush()
            postTopicCard()
            DiagnosticsLog.record("end: 終了処理を完了")
        } else {
            DiagnosticsLog.record("end: 致命的エラーによる終了（再開待ち）")
            // 致命的エラー。タイムラインは残っているので履歴を引き継いで再開できる
            // （永続化セッションも開いたままにし、再開後の発話を追記する）
            canResumeAfterFailure = activeTopicTitle != nil
        }
    }

    // MARK: - フィードバックカード

    /// セッション正常終了（手動 / goodbye）時に投稿する。
    /// 学習者の発話が 2 未満のセッションはスキップする（docs/specs/session-feedback.md）。
    private func postFeedbackCard(kind: SessionKind, topic: String, sessionID: UUID?) {
        let (transcript, learnerTurnCount) = sessionTranscript()
        guard learnerTurnCount >= 2 else {
            DiagnosticsLog.record("feedback: 発話 \(learnerTurnCount) 件のためスキップ")
            appendItem(.systemNotice(id: UUID(), text: "発話が少なかったためフィードバックは省略しました"))
            return
        }
        let card = FeedbackCard(
            sessionID: sessionID, kind: kind, topicTitle: topic, transcript: transcript)
        let cardID = card.id
        DiagnosticsLog.record("feedback: カード投稿 発話=\(learnerTurnCount)件 transcript=\(transcript.count)字")
        appendItem(.feedbackCard(card))
        Task { await fillFeedbackCard(cardID: cardID) }
    }

    /// 生成失敗時のリトライ（カード内ボタンから）。
    func retryFeedback(cardID: UUID) {
        guard let card = findFeedbackCard(cardID), !card.isLoading, card.feedback == nil else { return }
        DiagnosticsLog.record("feedback: リトライ")
        updateFeedbackCard(cardID) {
            $0.isLoading = true
            $0.errorText = nil
        }
        Task { await fillFeedbackCard(cardID: cardID) }
    }

    private func fillFeedbackCard(cardID: UUID) async {
        guard let card = findFeedbackCard(cardID) else { return }
        guard let apiKey = readKey(KeychainStore.anthropicAPIKeyAccount) else {
            DiagnosticsLog.record("!! feedback: Anthropic API キーが未設定")
            updateFeedbackCard(cardID) {
                $0.isLoading = false
                $0.errorText = "Anthropic API キーが未設定です。.secrets/anthropic-api-key を用意して再インストールしてください。"
            }
            return
        }
        do {
            let (feedback, usage) = try await SessionFeedbackClient().generateFeedback(
                apiKey: apiKey, kind: card.kind, topic: card.topicTitle,
                transcript: card.transcript)
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
            // 表示に渡った総評そのもの（生の出力と突き合わせて、途切れが
            // API 側かアプリ側かを切り分ける。docs/plans/feedback-truncated.md Phase 2）
            DiagnosticsLog.record(
                "feedback: カードへ反映 summary=\(DiagnosticsSnippet.make(feedback.summary, limit: 400))")
        } catch {
            DiagnosticsLog.record("!! feedback: 生成に失敗 \(error.localizedDescription)")
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
    /// 学習者ファーストのセッションでは開始時と同じく [Memory: ...] だけ（無ければ何も置かない）。
    /// 単語・クイズは開始時と同じく [New word: X] / [Quiz words: X] の 1 行だけ
    /// （学習者ファーストにはならない）。UI の練習モードではなく開始時のセッション種別で
    /// 組み立てる（クイズ中のエラー再開が [New word:] にならないように）。
    private func rebuildHistory(topic: String) -> [ConversationMessage] {
        var sessionItems: [TimelineItem] = []
        for item in timeline.reversed() {
            if case .sessionDivider = item { break }
            sessionItems.append(item)
        }
        var history: [ConversationMessage] = []
        if activeSessionKind == .conversation, Self.isLearnerFirstTopic(topic) {
            if let memoryLine = SessionOpeningMessage.composeMemoryOnly(
                memoryNote: activeMemoryNote)
            {
                history.append(ConversationMessage(role: .user, text: memoryLine))
            }
        } else {
            history.append(ConversationMessage(
                role: .user,
                text: SessionOpeningMessage.compose(
                    kind: activeSessionKind, topic: topic, memoryNote: activeMemoryNote)))
        }
        var pendingScript: [String] = []
        func flushScript() {
            guard !pendingScript.isEmpty else { return }
            // 先頭が assistant の履歴は Anthropic API が受け付けないため落とす
            // （学習者ファーストで第一声が残っていないケース。実際にはまず起きない）
            defer { pendingScript = [] }
            guard !history.isEmpty else { return }
            history.append(ConversationMessage(
                role: .assistant, text: pendingScript.joined(separator: "\n")))
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

    /// 練習モードを切り替えられるか（ヘッダのピルの有効 / 無効）。
    /// 会話の途中でキャラの役割が変わるのは破綻するため、セッション中とエラー再開待ちは切り替えない。
    var canChangePracticeMode: Bool {
        session == nil && !canResumeAfterFailure
    }

    func setPracticeMode(_ mode: PracticeMode) {
        guard practiceMode != mode, canChangePracticeMode else { return }
        practiceMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.practiceModeKey)
        replaceTrailingCard(with: mode)
    }

    /// モード切替の副作用は「末尾の未使用カードを現モードのカードに差し替える」だけ
    /// （システム通知は出さない。ヘッダの表示とカードが変わることで十分伝わる）。
    /// 生成中のカードを捨てた場合、生成完了時の `updateCard` は対象を見つけられず何もしない
    /// = 1 回ぶんの無駄打ちになるが、切替は頻繁ではないので許容する（キャンセルはしない）。
    private func replaceTrailingCard(with mode: PracticeMode) {
        let replacement = Self.cardReplacement(in: timeline, newMode: mode)
        guard let index = replacement.removedIndex else { return }
        if let carryOver = replacement.carryOver {
            carryOverCandidates = carryOver
        }
        timeline.remove(at: index)
        postTopicCard()
    }

    /// モード切替でカードをどう差し替えるか（純関数）。
    /// 対象は末尾の未使用トピックカードだけで、使用済みカード（過去の履歴）には触らない。
    struct CardReplacement {
        /// 取り除くカードの位置（差し替え不要なら nil）
        var removedIndex: Int?
        /// 持ち越しへ戻す候補（戻さない = 現状維持なら nil）。
        /// 会話カードを捨てるときだけ値が入り、会話モードへ帰ってきたときに生きる
        var carryOver: [TopicCandidate]?
    }

    static func cardReplacement(
        in timeline: [TimelineItem], newMode: PracticeMode
    ) -> CardReplacement {
        guard let index = timeline.lastIndex(where: {
            if case .topicCard = $0 { return true } else { return false }
        }), case .topicCard(let card) = timeline[index],
            !card.isUsed, card.mode != newMode
        else {
            return CardReplacement()
        }
        return CardReplacement(
            removedIndex: index,
            carryOver: card.mode == .conversation
                ? Array(card.candidates.prefix(topicCandidateCount)) : nil)
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
            if newState == .listening, !awaitsOpeningTurn {
                if !pendingAutoTexts.isEmpty {
                    sendText(pendingAutoTexts.removeFirst())
                } else if DebugLaunchArguments.shouldEndSession, !didAutoEndSession, session != nil {
                    // 自動送信ぶんを送り終えた。終了ボタンと同じ導線でセッションを閉じる
                    didAutoEndSession = true
                    endSession()
                }
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
            #if DEBUG
            awaitsOpeningTurn = false
            #endif
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

    /// セッション区切りの表示全文（純関数）。会話・単語は「日付 ラベル」、
    /// クイズは日付を付けず固定文言「クイズ」だけにする（日付があっても出題の役に立たない）。
    /// 開始時と復元時の両方がこれを通る（再起動で日付が復活しない）。
    static func dividerText(kind: SessionKind, title: String, date: Date) -> String {
        let label = dividerLabel(kind: kind, title: title)
        return kind == .quiz ? label : "\(dividerDateText(for: date)) \(label)"
    }

    /// セッション区切りの日付以降の文言（単語セッションは練習語だと分かるよう `単語:` を前置する）。
    /// クイズは**出題語を出さない**固定文言 ―― 区切りはクイズ開始と同時に表示されるので、
    /// 語を出すと答えが見えてクイズにならない（docs/plans/quiz-one-word.md）。
    static func dividerLabel(kind: SessionKind, title: String) -> String {
        switch kind {
        case .conversation: return title
        case .word: return "単語: \(title)"
        case .quiz: return "クイズ"
        }
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
