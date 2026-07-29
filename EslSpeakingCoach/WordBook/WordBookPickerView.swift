import SwiftUI

/// 単語帳（esl.chobi.me）から練習する語を選ぶシート。
/// 行タップで即セッション開始（前に練習した語のピルと同じ流儀。シートを閉じて startSession）。
struct WordBookPickerView: View {
    /// 選んだ語で練習を始める（呼び出し側で startSession へつなぐ）
    let onSelect: (String) -> Void

    @State private var store = WordBookPickerStore()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            content
                .navigationTitle("単語帳から選ぶ")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("閉じる") { dismiss() }
                    }
                }
                .searchable(
                    text: $store.searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "単語を検索")
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
        .task {
            #if DEBUG
            if let query = DebugLaunchArguments.wordBookInitialQuery {
                store.searchText = query
            }
            #endif
            await store.loadInitial()
            #if DEBUG
            if DebugLaunchArguments.shouldPickFirstWordBookWord {
                // デバウンス中の検索があれば結果を待ってから先頭の語を選ぶ（E2E 用）
                await store.searchTask?.value
                if let first = store.entries.first {
                    select(first.word)
                }
            }
            #endif
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .loading:
            ProgressView("単語帳を読み込み中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            failedView(message)
        case .loaded:
            if store.entries.isEmpty {
                emptyView
            } else {
                wordList
            }
        }
    }

    private var wordList: some View {
        List {
            ForEach(store.entries) { entry in
                Button {
                    select(entry.word)
                } label: {
                    entryRow(entry)
                }
                .buttonStyle(.plain)
            }
            paginationFooter
        }
        .listStyle(.plain)
    }

    private func entryRow(_ entry: WordBookEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(entry.word)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(ChatTheme.aiText)
                if let cefrLevel = entry.cefrLevel {
                    Text(cefrLevel)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(ChatTheme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(ChatTheme.topicPill, in: Capsule())
                }
                if let partOfSpeech = entry.partOfSpeech {
                    Text(partOfSpeech)
                        .font(.caption2)
                        .foregroundStyle(ChatTheme.systemText)
                }
            }
            if let meaning = entry.meaning {
                Text(meaning)
                    .font(.caption)
                    .foregroundStyle(ChatTheme.systemText)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// リスト末尾の追い読み行。到達で次ページを取り、失敗したら再試行ボタンに変わる。
    @ViewBuilder
    private var paginationFooter: some View {
        if store.loadMoreFailed {
            Button {
                Task { await store.loadMore() }
            } label: {
                Label("続きを読み込めませんでした。もう一度", systemImage: "arrow.clockwise")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
            }
            .tint(ChatTheme.accent)
        } else if store.isLoadingMore {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
        } else if store.canLoadMore {
            Color.clear
                .frame(height: 1)
                .onAppear {
                    Task { await store.loadMore() }
                }
        }
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(ChatTheme.systemText)
                .multilineTextAlignment(.center)
            Button {
                Task { await store.retry() }
            } label: {
                Label("もう一度", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(ChatTheme.accent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        Text(store.searchText.isEmpty
            ? "単語帳に語がありません"
            : "「\(store.searchText)」に一致する語がありません")
            .font(.footnote)
            .foregroundStyle(ChatTheme.systemText)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func select(_ word: String) {
        dismiss()
        onSelect(word)
    }
}

#Preview {
    WordBookPickerView(onSelect: { _ in })
}
