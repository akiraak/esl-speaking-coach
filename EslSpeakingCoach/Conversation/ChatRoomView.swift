import SwiftUI

/// 起動直後に表示される主画面。常設グループトークルーム（screen-layout.md のトーク画面）。
struct ChatRoomView: View {
    @State private var store = ChatRoomStore()
    @State private var isShowingAdmin = false
    @State private var isShowingTopicInput = false
    @State private var isConfirmingEndSession = false
    @State private var customTopicText = ""
    @State private var customTopicCardID: UUID?
    /// 単語帳ピッカー（単語モードのカードの「単語帳から選ぶ」）
    @State private var isShowingWordBookPicker = false
    @State private var wordBookCardID: UUID?
    /// ランダム出題（単語モードのカードの「ランダムに選ぶ」）の取得中フラグ。
    /// カードの 3 ボタンを無効化して二重タップを防ぐ（docs/plans/wordbook-random-word.md）
    @State private var isFetchingRandomWord = false
    /// ランダム出題の失敗アラート（nil でないとき表示）
    @State private var randomWordErrorText: String?
    @State private var draftText = ""
    /// ユーザーが手動で遡っている間は自動スクロールしない。
    /// 手動スクロールが最下部付近で終わったら再開する
    @State private var isAutoScrollEnabled = true

    private static let bottomAnchorID = "timeline-bottom"
    /// 固定表示の下端バー（高さ 44 + 下余白 12）に隠れない分のスクロール下余白
    private static let bottomBarInset: CGFloat = 72

    var body: some View {
        VStack(spacing: 0) {
            header
            timeline
            ChatInputBar(
                store: store,
                draftText: $draftText,
                onSend: sendDraft)
        }
        .background(ChatTheme.chatBackground.ignoresSafeArea())
        // ダークモードの暖色トーン再設計は未決（screen-layout.md）。決まるまでライト固定
        .preferredColorScheme(.light)
        .sheet(isPresented: $isShowingAdmin) {
            #if DEBUG
            AdminView(
                historyStore: store.historyStore, usageStore: store.usageStore,
                memoryStore: store.memoryStore,
                initialTab: DebugLaunchArguments.adminInitialTab)
            #else
            AdminView(
                historyStore: store.historyStore, usageStore: store.usageStore,
                memoryStore: store.memoryStore)
            #endif
        }
        // シートを閉じてからセッションを開始する（ピルタップと同じ経路）
        .sheet(isPresented: $isShowingWordBookPicker) {
            WordBookPickerView(onSelect: { word in
                store.startSession(topic: word, fromCard: wordBookCardID)
                wordBookCardID = nil
            })
        }
        // ボタンはセッション終了で消えるので、ダイアログはボタンではなく画面側に付ける
        .alert(
            isWordMode ? "この単語を終了しますか？" : "このトピックを終了しますか？",
            isPresented: $isConfirmingEndSession
        ) {
            Button("終了する") { store.endSession() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("会話をまとめてフィードバックを作ります")
        }
        // ピッカーと同じ文言・同じ分類（WordBookError.errorDescription）で失敗を伝える
        .alert(
            "ランダムに選べませんでした",
            isPresented: Binding(
                get: { randomWordErrorText != nil },
                set: { if !$0 { randomWordErrorText = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(randomWordErrorText ?? "")
        }
        .alert(isWordMode ? "練習する単語を入力" : "自分でトピックを作る", isPresented: $isShowingTopicInput) {
            TextField(isWordMode ? "例: get around to" : "例: 好きなラーメン屋", text: $customTopicText)
                .autocorrectionDisabled()
            Button("開始") { submitCustomTopic() }
            Button("キャンセル", role: .cancel) { customTopicText = "" }
        } message: {
            Text(isWordMode ? "英語の単語・熟語を入力してください" : "話したいトピックを英語で入力してください")
        }
        .onAppear {
            store.onAppear()
            #if DEBUG
            if DebugLaunchArguments.shouldOpenAdmin {
                isShowingAdmin = true
            }
            if DebugLaunchArguments.shouldOpenWordBookPicker {
                isShowingWordBookPicker = true
            }
            if DebugLaunchArguments.shouldStartRandomWord {
                startRandomWordSessionFromLatestCard()
            }
            #endif
        }
    }

    // MARK: - ヘッダ

    private var header: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Text("ESL Group")
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(ChatTheme.aiText)
                Text("(3)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ChatTheme.nameLabel)
            }
            Spacer()
            modePill
            Button {
                isShowingAdmin = true
            } label: {
                Image(systemName: "chart.bar.doc.horizontal")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(ChatTheme.aiText)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("管理画面")
        }
        .animation(.easeOut(duration: 0.15), value: store.practiceMode)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            ChatTheme.barBackground
                .shadow(color: ChatTheme.bubbleShadow, radius: 3, y: 1)
                .ignoresSafeArea(edges: .top))
    }

    /// 練習モード（会話 / 単語）の選択。タップで両方を並べて出し、選んだほうへ切り替える
    /// （押すまで何になるか分からないトグルより、開いて選ぶほうが分かりやすい）。
    /// セッション中・エラー再開待ちは無効（会話の途中でキャラの役割が変わると破綻するため）。
    private var modePill: some View {
        Menu {
            // インラインの Picker にすると現在のモードにチェックが付く（印を自前で描かない）
            Picker("練習モード", selection: practiceModeSelection) {
                ForEach(PracticeMode.allCases, id: \.self) { mode in
                    Label(mode.displayName, systemImage: mode.symbolName)
                        .tag(mode)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: store.practiceMode.symbolName)
                Text(store.practiceMode.displayName)
                // 押すとメニューが開くことを見た目で示す
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(ChatTheme.topicPillSelectedText)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(ChatTheme.topicPill, in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .disabled(!store.canChangePracticeMode)
        .opacity(store.canChangePracticeMode ? 1 : 0.45)
        .accessibilityLabel("練習モード: \(store.practiceMode.displayName)")
        .accessibilityHint("タップで会話 / 単語を選びます")
    }

    /// 同じモードを選んだときは setPracticeMode 側の guard で何も起きない
    /// （カードの差し替えも走らない）。
    private var practiceModeSelection: Binding<PracticeMode> {
        Binding(
            get: { store.practiceMode },
            set: { store.setPracticeMode($0) })
    }

    // MARK: - タイムライン

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(store.timeline) { item in
                        timelineRow(item)
                            .id(item.id)
                    }
                    if !store.partialTranscript.isEmpty {
                        LiveTranscriptRow(text: store.partialTranscript)
                    }
                    if store.voiceState == .thinking {
                        TypingIndicatorRow()
                    }
                    // 最下部アンカー。固定表示の下端バーに最新メッセージが隠れないよう、
                    // バーの高さぶんの余白をアンカー自体に持たせる
                    Color.clear
                        .frame(height: isBottomBarVisible ? Self.bottomBarInset : 1)
                        .id(Self.bottomAnchorID)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            // 起動直後は履歴復元の直後に最下部から始める
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .scrollDismissesKeyboard(.interactively)
            .onScrollPhaseChange { oldPhase, newPhase, context in
                switch newPhase {
                case .tracking, .interacting:
                    // ユーザーがスクロールを始めた（コンテンツ追記による自動移動はここに来ない）
                    isAutoScrollEnabled = false
                case .idle where oldPhase.isUserDriven:
                    // 指を離して止まった位置で判定する。プログラム側スクロールの
                    // 完了（.animating → .idle）で誤って追従を切らないよう限定する
                    let geometry = context.geometry
                    isAutoScrollEnabled =
                        geometry.contentOffset.y + geometry.containerSize.height
                        >= geometry.contentSize.height - 120
                default:
                    break
                }
            }
            .onChange(of: store.timelineRevision) {
                scrollToBottom(proxy)
            }
            .task {
                // 履歴復元は .onAppear（初期レイアウト後）に走り、LazyVStack は
                // 画面外セルを推定高さで扱うため初期位置がずれる。
                // 高さが確定するまで数フレーム、アニメーション無しで最下部へ寄せ直す
                for _ in 0..<3 {
                    try? await Task.sleep(for: .milliseconds(50))
                    guard isAutoScrollEnabled else { return }
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            }
            .onChange(of: store.partialTranscript) {
                if !store.partialTranscript.isEmpty { scrollToBottom(proxy) }
            }
            .onChange(of: store.voiceState) {
                scrollToBottom(proxy)
            }
            // スクロールに乗せずタイムライン下端へ固定する（会話追記でも位置が動かない）
            .overlay(alignment: .bottom) {
                if isBottomBarVisible {
                    TimelineBottomBar(
                        isTranslationVisible: store.isTranslationVisible,
                        isSessionActive: isEndSessionButtonVisible,
                        practiceMode: store.practiceMode,
                        onToggleTranslation: {
                            withAnimation(.easeOut(duration: 0.2)) {
                                store.setTranslationVisible(!store.isTranslationVisible)
                            }
                        },
                        onEndSession: { isConfirmingEndSession = true })
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                }
            }
        }
    }

    /// 入力アラート・終了アラートの文言の出し分け
    /// （カードは常に現在のモードのもので、セッション中はモードを切り替えられないのでモードだけ見る）。
    private var isWordMode: Bool {
        store.practiceMode == .word
    }

    /// 下端バーを出す条件（翻訳トグルは常時表示。エラー再開バー表示中だけは引っ込める）。
    private var isBottomBarVisible: Bool {
        !store.canResumeAfterFailure
    }

    /// 終了ボタンを出す条件（セッション中。エラー再開バー表示中は出さない）。
    private var isEndSessionButtonVisible: Bool {
        store.isSessionActive && !store.canResumeAfterFailure
    }

    @ViewBuilder
    private func timelineRow(_ item: ChatRoomStore.TimelineItem) -> some View {
        switch item {
        case .sessionDivider(_, let text, _):
            SystemPillRow(text: text, emphasized: true)
        case .aiMessage(let message):
            AIMessageRow(
                message: message,
                isSpeaking: store.speakingUtteranceID == message.id
                    && store.voiceState == .speaking,
                translation: store.translationDisplay(
                    id: message.id, translation: message.translation))
        case .userMessage(let message):
            UserMessageRow(
                message: message,
                translation: store.translationDisplay(
                    id: message.id, translation: message.translation))
        case .topicCard(let card):
            TopicCardView(
                card: card,
                onSelect: { title in store.startSession(topic: title, fromCard: card.id) },
                onRegenerate: { store.regenerateTopics(cardID: card.id) },
                onCustomTopic: {
                    customTopicCardID = card.id
                    customTopicText = ""
                    isShowingTopicInput = true
                },
                onWordBook: {
                    wordBookCardID = card.id
                    isShowingWordBookPicker = true
                },
                onRandomWord: { startRandomWordSession(cardID: card.id) },
                isRandomWordLoading: isFetchingRandomWord)
        case .feedbackCard(let card):
            FeedbackCardView(
                card: card,
                onRetry: { store.retryFeedback(cardID: card.id) })
        case .systemNotice(_, let text):
            SystemPillRow(text: text, emphasized: false)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard isAutoScrollEnabled else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
    }

    // MARK: - 操作

    private func sendDraft() {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draftText = ""
        store.sendText(text)
    }

    private func submitCustomTopic() {
        let topic = customTopicText.trimmingCharacters(in: .whitespacesAndNewlines)
        customTopicText = ""
        guard !topic.isEmpty else { return }
        store.startSession(topic: topic, fromCard: customTopicCardID)
        customTopicCardID = nil
    }

    /// 単語カードの「ランダムに選ぶ」。単語帳を全件取得し、まだ練習していない語を
    /// ランダムに選んで**即**セッションを開始する（確認は挟まない。委ねる導線なので）。
    /// 全語練習済みなら全語からのフォールバック（docs/plans/wordbook-random-word.md）。
    private func startRandomWordSession(cardID: UUID) {
        guard !isFetchingRandomWord, !store.isSessionActive else { return }
        isFetchingRandomWord = true
        Task {
            defer { isFetchingRandomWord = false }
            do {
                guard
                    let secret = (try? KeychainStore().read(
                        account: KeychainStore.wordBookAPISecretAccount)) ?? nil,
                    !secret.isEmpty
                else {
                    throw WordBookError.missingSecret
                }
                let all = try await WordBookClient().fetchAllWords(secret: secret)
                let unpracticed = ChatRoomStore.unpracticedWords(
                    all: all, practiced: store.historyStore.practicedWordsAll())
                var rng = SystemRandomNumberGenerator()
                guard let choice = ChatRoomStore.randomWordChoice(
                    unpracticed: unpracticed, all: all, using: &rng)
                else {
                    randomWordErrorText = "単語帳に単語がありません"
                    return
                }
                DiagnosticsLog.record(
                    "randomWord: 全\(all.count)語 未練習\(unpracticed.count)語 → \(choice.entry.word)"
                    + (choice.isFallback ? "（全語練習済みのため全語から選択）" : ""))
                store.startSession(topic: choice.entry.word, fromCard: cardID)
            } catch {
                DiagnosticsLog.record("!! randomWord: 取得に失敗 \(error.localizedDescription)")
                randomWordErrorText = (error as? WordBookError)?.errorDescription
                    ?? "単語帳を取得できませんでした: \(error.localizedDescription)"
            }
        }
    }

    #if DEBUG
    /// -start-random-word: 末尾の未使用の単語カードで「ランダムに選ぶ」をタップした扱いにする。
    private func startRandomWordSessionFromLatestCard() {
        for item in store.timeline.reversed() {
            guard case .topicCard(let card) = item else { continue }
            if card.mode == .word, !card.isUsed {
                startRandomWordSession(cardID: card.id)
            }
            return
        }
    }
    #endif
}

private extension ScrollPhase {
    /// 指の操作に由来するフェーズ（プログラム側の `.animating` と区別する）。
    var isUserDriven: Bool {
        switch self {
        case .tracking, .interacting, .decelerating: return true
        default: return false
        }
    }
}

#Preview {
    ChatRoomView()
}
