import SwiftUI

/// 管理画面「会話」タブ: セッション一覧（新しい順）→ 会話全文の詳細。
/// スワイプ削除でセッションと、紐づく利用記録を削除する。
struct SessionListView: View {
    let historyStore: ChatHistoryStore
    let usageStore: UsageStore

    @State private var summaries: [ChatHistoryStore.SessionSummary] = []
    @State private var costsBySessionID: [UUID: Double] = [:]

    var body: some View {
        Group {
            if summaries.isEmpty {
                ContentUnavailableView(
                    "会話履歴はまだありません",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("トピックを選んで会話するとここに記録されます"))
            } else {
                List {
                    ForEach(summaries) { summary in
                        NavigationLink {
                            SessionDetailView(
                                historyStore: historyStore,
                                usageStore: usageStore,
                                summary: summary)
                        } label: {
                            row(summary)
                        }
                    }
                    .onDelete(perform: delete)
                }
                .listStyle(.insetGrouped)
            }
        }
        .onAppear(perform: reload)
    }

    private func row(_ summary: ChatHistoryStore.SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary.topicTitle)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 8) {
                Text(summary.startedAt.formatted(date: .abbreviated, time: .shortened))
                Text("\(summary.messageCount) 発話")
                if summary.hasFeedback {
                    Label("フィードバック", systemImage: "checkmark.seal")
                        .labelStyle(.iconOnly)
                }
                Spacer()
                Text(formattedUSD(costsBySessionID[summary.id] ?? 0))
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func reload() {
        summaries = historyStore.sessionSummaries()
        costsBySessionID = Dictionary(
            uniqueKeysWithValues: summaries.map {
                ($0.id, usageStore.sessionCostUSD(sessionID: $0.id))
            })
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let id = summaries[index].id
            historyStore.deleteSession(id: id)
            usageStore.deleteRecords(sessionID: id)
        }
        reload()
    }
}

/// セッション詳細: speaker 別の会話全文 + 保存済みフィードバック。
struct SessionDetailView: View {
    let historyStore: ChatHistoryStore
    let usageStore: UsageStore
    let summary: ChatHistoryStore.SessionSummary

    @State private var messages: [ChatHistoryStore.MessageSnapshot] = []
    @State private var feedback: SessionFeedback?
    @State private var costUSD = 0.0

    var body: some View {
        List {
            Section {
                LabeledContent("開始", value: summary.startedAt.formatted(date: .abbreviated, time: .shortened))
                if let endedAt = summary.endedAt {
                    LabeledContent("終了", value: endedAt.formatted(date: .omitted, time: .shortened))
                }
                LabeledContent("推定料金", value: formattedUSD(costUSD))
            }

            Section("会話") {
                ForEach(messages) { message in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(speakerName(message.speaker))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(speakerColor(message.speaker))
                        Text(message.text)
                            .font(.subheadline)
                    }
                    .padding(.vertical, 2)
                }
            }

            if let feedback {
                Section("フィードバック") {
                    Text(feedback.summary)
                        .font(.subheadline)
                    ForEach(Array(feedback.corrections.enumerated()), id: \.offset) { _, correction in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("✗ \(correction.original)")
                                .foregroundStyle(ChatTheme.liveText)
                            Text("✓ \(correction.improved)")
                                .foregroundStyle(ChatTheme.feedbackGood)
                            Text(correction.note)
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .padding(.vertical, 2)
                    }
                    ForEach(Array(feedback.tryPhrases.enumerated()), id: \.offset) { _, phrase in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(phrase.phrase)
                                .font(.caption.weight(.semibold))
                            Text(phrase.meaning)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(summary.topicTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            messages = historyStore.messages(sessionID: summary.id)
            feedback = historyStore.feedback(sessionID: summary.id)
            costUSD = usageStore.sessionCostUSD(sessionID: summary.id)
        }
    }

    private func speakerName(_ speaker: MessageSpeaker) -> String {
        speaker.character?.displayName ?? "あなた"
    }

    private func speakerColor(_ speaker: MessageSpeaker) -> Color {
        speaker.character?.avatarColor ?? ChatTheme.userBubble
    }
}
