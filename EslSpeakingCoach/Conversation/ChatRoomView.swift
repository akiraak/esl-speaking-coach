import SwiftUI

/// 起動直後に表示される主画面。常設グループトークルーム（screen-layout.md のトーク画面）。
struct ChatRoomView: View {
    @State private var store = ChatRoomStore()
    @State private var isShowingSettings = false
    @State private var isShowingAdmin = false
    @State private var isShowingTopicInput = false
    @State private var customTopicText = ""
    @State private var customTopicCardID: UUID?
    @State private var draftText = ""
    /// ユーザーが手動で遡っている間は自動スクロールしない。
    /// 手動スクロールが最下部付近で終わったら再開する
    @State private var isAutoScrollEnabled = true

    private static let bottomAnchorID = "timeline-bottom"

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
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $isShowingAdmin) {
            #if DEBUG
            AdminView(
                historyStore: store.historyStore, usageStore: store.usageStore,
                memoryStore: store.memoryStore,
                startOnUsage: DebugLaunchArguments.adminOpensOnUsageTab)
            #else
            AdminView(
                historyStore: store.historyStore, usageStore: store.usageStore,
                memoryStore: store.memoryStore)
            #endif
        }
        .alert("自分でトピックを作る", isPresented: $isShowingTopicInput) {
            TextField("例: 好きなラーメン屋", text: $customTopicText)
                .autocorrectionDisabled()
            Button("開始") { submitCustomTopic() }
            Button("キャンセル", role: .cancel) { customTopicText = "" }
        } message: {
            Text("話したいトピックを英語で入力してください")
        }
        .onAppear {
            store.onAppear()
            if store.isAnthropicKeyMissing {
                isShowingSettings = true
            }
            #if DEBUG
            if DebugLaunchArguments.shouldOpenAdmin {
                isShowingAdmin = true
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
            Menu {
                Button {
                    store.endSession()
                } label: {
                    Label("トピックを終える", systemImage: "flag.checkered")
                }
                .disabled(!store.isSessionActive)
                Button {
                    isShowingAdmin = true
                } label: {
                    Label("管理画面", systemImage: "chart.bar.doc.horizontal")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(ChatTheme.aiText)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            Button {
                isShowingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(ChatTheme.aiText)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            ChatTheme.barBackground
                .shadow(color: ChatTheme.bubbleShadow, radius: 3, y: 1)
                .ignoresSafeArea(edges: .top))
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
                    Color.clear
                        .frame(height: 1)
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
        }
    }

    @ViewBuilder
    private func timelineRow(_ item: ChatRoomStore.TimelineItem) -> some View {
        switch item {
        case .sessionDivider(_, let text):
            SystemPillRow(text: text, emphasized: true)
        case .aiMessage(let message):
            AIMessageRow(
                message: message,
                isSpeaking: store.speakingUtteranceID == message.id
                    && store.voiceState == .speaking)
        case .userMessage(_, let text):
            UserMessageRow(text: text)
        case .topicCard(let card):
            TopicCardView(
                card: card,
                onSelect: { title in store.startSession(topic: title, fromCard: card.id) },
                onRegenerate: { store.regenerateTopics(cardID: card.id) },
                onCustomTopic: {
                    customTopicCardID = card.id
                    customTopicText = ""
                    isShowingTopicInput = true
                })
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
