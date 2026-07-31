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
            // 単語・クイズのセッションは topicTitle が語そのものなので、印が無いと区別できない
            Text(
                summary.mode.sessionListMarker.map { "\($0) \(summary.topicTitle)" }
                    ?? summary.topicTitle)
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

    @State private var entries: [Entry] = []
    @State private var feedback: SessionFeedback?
    @State private var costUSD = 0.0

    /// 発話と調査用ログを時系列にマージした 1 行。
    private enum Entry: Identifiable {
        case message(ChatHistoryStore.MessageSnapshot)
        case log(ChatHistoryStore.LogSnapshot)

        var id: UUID {
            switch self {
            case .message(let message): return message.id
            case .log(let log): return log.id
            }
        }

        var createdAt: Date {
            switch self {
            case .message(let message): return message.createdAt
            case .log(let log): return log.createdAt
            }
        }
    }

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
                ForEach(entries) { entry in
                    switch entry {
                    case .message(let message):
                        VStack(alignment: .leading, spacing: 2) {
                            Text(speakerName(message.speaker))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(speakerColor(message.speaker))
                            Text(message.text)
                                .font(.subheadline)
                            if let translation = message.translation {
                                Text(translation)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    case .log(let log):
                        logRow(log)
                    }
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
            entries = mergedEntries()
            feedback = historyStore.feedback(sessionID: summary.id)
            costUSD = usageStore.sessionCostUSD(sessionID: summary.id)
        }
    }

    /// 調査用ログの行（レイテンシ計測・技術通知・エラー）。トーク画面には出ないのでここでだけ見る。
    private func logRow(_ log: ChatHistoryStore.LogSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(logMark(log.kind))
            Text(log.text)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .foregroundStyle(log.kind == .error ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
        .padding(.vertical, 1)
    }

    private func logMark(_ kind: SessionLogKind) -> String {
        switch kind {
        case .metrics: return "⏱"
        case .notice: return "ℹ️"
        case .error: return "⚠️"
        }
    }

    /// 発話と調査用ログを記録時刻順に 1 本のリストへまとめる。
    private func mergedEntries() -> [Entry] {
        let messages = historyStore.messages(sessionID: summary.id).map(Entry.message)
        let logs = historyStore.logs(sessionID: summary.id).map(Entry.log)
        return (messages + logs).sorted { $0.createdAt < $1.createdAt }
    }

    private func speakerName(_ speaker: MessageSpeaker) -> String {
        speaker.character?.displayName ?? "あなた"
    }

    private func speakerColor(_ speaker: MessageSpeaker) -> Color {
        speaker.character?.avatarColor ?? ChatTheme.userBubble
    }
}
