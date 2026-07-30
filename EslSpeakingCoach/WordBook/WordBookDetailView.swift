import SwiftUI

/// 単語帳 1 語の詳細画面（docs/plans/wordbook-word-detail.md）。
/// ピッカーの NavigationStack に push され、`wordInfo` 全項目を表示する。
/// null / 空配列のセクションは丸ごと出さない。
struct WordBookDetailView: View {
    /// 「この単語を練習する」。ピッカーの行タップと同じ closure（シートを閉じて startSession）
    let onPractice: (String) -> Void

    @State private var store: WordBookDetailStore

    init(
        word: String,
        onPractice: @escaping (String) -> Void,
        fetchDetail: (@Sendable (String) async throws -> WordBookWordDetail)? = nil
    ) {
        self.onPractice = onPractice
        _store = State(initialValue: WordBookDetailStore(word: word, fetchDetail: fetchDetail))
    }

    var body: some View {
        content
            .navigationTitle(store.word)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { practiceButton }
            .task { await store.loadInitial() }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .loading:
            ProgressView("詳細を読み込み中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            failedView(message)
        case .loaded(let detail):
            detailScroll(detail)
        }
    }

    private func detailScroll(_ detail: WordBookWordDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection(detail)
                sensesSection(detail.senses)
                examplesSection(detail.examples)
                inflectionsSection(detail.inflections)
                chipSection("コロケーション", items: detail.collocations)
                chipSection("類義語", items: detail.synonyms)
                chipSection("反意語", items: detail.antonyms)
                textSection("使い方ノート", text: detail.usageNote)
                textSection("よくある間違い", text: detail.commonMistakes)
                textSection("語源", text: detail.etymology)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 見出し（語 + CEFR + 使用域、発音）

    private func headerSection(_ detail: WordBookWordDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(detail.word)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(ChatTheme.aiText)
                if let cefrLevel = detail.cefrLevel {
                    Text(cefrLevel)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(ChatTheme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(ChatTheme.topicPill, in: Capsule())
                }
                if let register = detail.register {
                    Text(register)
                        .font(.caption)
                        .foregroundStyle(ChatTheme.systemText)
                }
            }
            let pronunciation = [detail.pronunciation.ipa, detail.pronunciation.syllables]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "  ")
            if !pronunciation.isEmpty {
                Text(pronunciation)
                    .font(.subheadline)
                    .foregroundStyle(ChatTheme.systemText)
            }
        }
    }

    // MARK: - セクション

    @ViewBuilder
    private func sensesSection(_ senses: [WordBookWordDetail.Sense]) -> some View {
        if !senses.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("語義")
                ForEach(Array(senses.enumerated()), id: \.offset) { index, sense in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(ChatTheme.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            (Text(sense.meaning)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(ChatTheme.aiText)
                                + Text("  \(sense.partOfSpeech)")
                                .font(.caption)
                                .foregroundStyle(ChatTheme.systemText))
                            Text(sense.englishDefinition)
                                .font(.subheadline)
                                .foregroundStyle(ChatTheme.aiText.opacity(0.85))
                            if let note = sense.note, !note.isEmpty {
                                Text(note)
                                    .font(.caption)
                                    .foregroundStyle(ChatTheme.systemText)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func examplesSection(_ examples: [WordBookWordDetail.Example]) -> some View {
        if !examples.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("例文")
                ForEach(Array(examples.enumerated()), id: \.offset) { _, example in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(example.english)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(ChatTheme.aiText)
                        Text(example.translation)
                            .font(.caption)
                            .foregroundStyle(ChatTheme.systemText)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func inflectionsSection(_ inflections: [WordBookWordDetail.Inflection]) -> some View {
        if !inflections.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("活用形")
                ForEach(Array(inflections.enumerated()), id: \.offset) { _, inflection in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(inflection.form)
                            .font(.caption)
                            .foregroundStyle(ChatTheme.systemText)
                        Text(inflection.text)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(ChatTheme.aiText)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func chipSection(_ title: String, items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle(title)
                ChipFlowLayout(spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        Text(item)
                            .font(.caption)
                            .foregroundStyle(ChatTheme.aiText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(ChatTheme.topicPill, in: Capsule())
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func textSection(_ title: String, text: String?) -> some View {
        if let text, !text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle(title)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(ChatTheme.aiText)
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.bold))
            .foregroundStyle(ChatTheme.accent)
    }

    // MARK: - 下部固定の練習開始ボタン・エラー表示

    /// 詳細の取得に失敗しても押せる（練習開始に wordInfo は要らない）。
    private var practiceButton: some View {
        Button {
            onPractice(store.word)
        } label: {
            Text("この単語を練習する")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(ChatTheme.accent, in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
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
}

/// チップを左寄せで並べ、行に収まらなければ折り返す簡易フローレイアウト。
private struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = makeRows(maxWidth: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var y = bounds.minY
        for row in makeRows(maxWidth: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func makeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let widthIfAppended = current.indices.isEmpty
                ? size.width
                : current.width + spacing + size.width
            if !current.indices.isEmpty, widthIfAppended > maxWidth {
                rows.append(current)
                current = Row(indices: [index], width: size.width, height: size.height)
            } else {
                current.indices.append(index)
                current.width = widthIfAppended
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty {
            rows.append(current)
        }
        return rows
    }
}

#Preview {
    NavigationStack {
        WordBookDetailView(
            word: "disability",
            onPractice: { _ in },
            fetchDetail: { word in
                WordBookWordDetail(
                    word: word,
                    senses: [
                        .init(
                            meaning: "障害",
                            englishDefinition: "a physical or mental condition that limits "
                                + "a person's movements, senses, or activities",
                            partOfSpeech: "noun",
                            note: "身体・精神の機能に関する語。婉曲的な言い換えに注意"),
                        .init(
                            meaning: "無能力・不利な条件",
                            englishDefinition: "a disadvantage or handicap",
                            partOfSpeech: "noun",
                            note: nil),
                    ],
                    pronunciation: .init(ipa: "/ˌdɪsəˈbɪləti/", syllables: "dis-uh-BIL-uh-tee"),
                    inflections: [.init(form: "plural", text: "disabilities")],
                    examples: [
                        .init(
                            english: "She has a learning disability.",
                            translation: "彼女には学習障害がある。"),
                        .init(
                            english: "The building has access for people with disabilities.",
                            translation: "その建物には障害のある人のための入口がある。"),
                    ],
                    collocations: ["learning disability", "physical disability", "disability benefits"],
                    synonyms: ["impairment", "handicap", "incapacity"],
                    antonyms: ["ability"],
                    usageNote: "人を指すときは people with disabilities のように person-first の言い方が好まれる。",
                    cefrLevel: "B2",
                    etymology: "dis-（否定）+ ability（能力）",
                    register: "フォーマル",
                    commonMistakes: "disable（動詞）・disabled（形容詞）と品詞を混同しやすい。")
            })
    }
}
