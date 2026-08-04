import SwiftUI
#if DEBUG
import UIKit
#endif

/// 管理画面（ヘッダメニューから開く）。会話内容の閲覧・キャラの記憶・AI 利用料金の確認。
/// ルートは項目一覧で、各項目は push して開く（項目が増えても破綻しないよう、5 つで窮屈だった
/// segmented picker から組み替えた。docs/plans/model-selection-in-admin.md Phase 1）。
/// 標準コンポーネント中心の簡素な作り。トーク画面に合わせてライト固定。
struct AdminView: View {
    let historyStore: ChatHistoryStore
    let usageStore: UsageStore
    let memoryStore: CharacterMemoryStore
    let modelSettings: ModelSettingsStore

    /// 管理画面の項目。**rawValue（表示名）は `-open-admin <表示名>` の指定キーなので変えない。**
    enum Tab: String, CaseIterable, Identifiable, Hashable {
        case sessions = "会話"
        case memory = "記憶"
        case usage = "料金"
        case diagnostics = "診断"
        case storage = "容量"
        case models = "モデル"
        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .sessions: return "bubble.left.and.bubble.right"
            case .memory: return "brain"
            case .usage: return "dollarsign.circle"
            case .diagnostics: return "stethoscope"
            case .storage: return "internaldrive"
            case .models: return "cpu"
            }
        }
    }

    /// ルートの並び。項目を足すときはここに 1 行足す（Tab の定義順とは独立）。
    /// **全 Tab がちょうど 1 回ずつ現れること**をテストで担保する（入れ忘れ = ルートから辿れない項目）。
    static let sections: [(title: String, tabs: [Tab])] = [
        ("記録", [.sessions, .memory]),
        ("コスト", [.usage, .storage]),
        ("設定", [.models]),
        ("開発", [.diagnostics]),
    ]

    @Environment(\.dismiss) private var dismiss
    /// push 中の項目。`-open-admin <タブ名>` は初期値として積む（起動引数の互換）
    @State private var path: [Tab]
    @State private var sessionCount = 0
    @State private var monthCostUSD = 0.0
    @State private var memoryUpdatedAt: Date?
    @State private var diagnosticsUpdatedAt: Date?
    /// 計測が終わるまで nil（ディレクトリ走査なのでバックグラウンドで測る）
    @State private var storageBytes: Int64?
    /// 既定から変えている経路の数
    @State private var overriddenModelCount = 0
    #if DEBUG
    @State private var exportFile: ExportFile?

    /// 共有シートへ渡す書き出し済みファイル（`.sheet(item:)` 用に Identifiable にする）。
    private struct ExportFile: Identifiable {
        let url: URL
        var id: String { url.path }
    }
    #endif

    init(
        historyStore: ChatHistoryStore, usageStore: UsageStore,
        memoryStore: CharacterMemoryStore, modelSettings: ModelSettingsStore,
        initialTab: Tab? = nil
    ) {
        self.historyStore = historyStore
        self.usageStore = usageStore
        self.memoryStore = memoryStore
        self.modelSettings = modelSettings
        _path = State(initialValue: initialTab.map { [$0] } ?? [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(Self.sections, id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.tabs) { tab in
                            NavigationLink(value: tab) { row(tab) }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("管理")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Tab.self, destination: destination)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
                #if DEBUG
                // モデル評価の fixture 用にセッションを JSON で書き出す（AirDrop で Mac へ渡す）。
                // docs/plans/cheap-chinese-ai-models.md の Phase 5 Step 0
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        exportFile = (try? SessionExporter.writeJSON(
                            historyStore: historyStore, memoryStore: memoryStore))
                            .map(ExportFile.init)
                    } label: {
                        Label("セッション書き出し", systemImage: "square.and.arrow.up")
                    }
                }
                #endif
            }
            // 子画面から戻ったときも呼ばれるので、ログのクリアや履歴削除がサマリに反映される
            .onAppear(perform: reloadSummaries)
            #if DEBUG
            // 共有シートを閉じたら書き出しファイルは用済み（tmp に残骸を溜めない。
            // docs/plans/archive/chat-storage-audit.md Phase 2）
            .sheet(item: $exportFile, onDismiss: { SessionExporter.cleanUpLeftovers() }) { file in
                ActivityShareSheet(items: [file.url])
            }
            #endif
        }
        .preferredColorScheme(.light)
        .tint(ChatTheme.accent)
    }

    /// ルートの 1 行。右肩に現在値のサマリを出して、開かずに済むようにする。
    private func row(_ tab: Tab) -> some View {
        HStack {
            // アイコンだけアクセント色にする（Label 全体に付けると見出しまで色が付く。
            // List 内の Label は .tint を拾わずシステム既定の青になるため明示する）
            Label {
                Text(tab.rawValue)
            } icon: {
                Image(systemName: tab.systemImage).foregroundStyle(ChatTheme.accent)
            }
            Spacer()
            if let summary = summary(for: tab) {
                Text(summary)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func summary(for tab: Tab) -> String? {
        switch tab {
        case .sessions:
            return "\(sessionCount) 件"
        case .memory:
            return memoryUpdatedAt.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "未保存"
        case .usage:
            return "今月 \(formattedUSD(monthCostUSD))"
        case .diagnostics:
            return diagnosticsUpdatedAt.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "なし"
        case .storage:
            return storageBytes.map(StorageAudit.formattedBytes) ?? "計測中…"
        case .models:
            return overriddenModelCount == 0 ? "既定" : "\(overriddenModelCount) 経路変更"
        }
    }

    /// push 先。タイトルと「閉じる」は各項目で共通なのでここで付ける
    /// （子画面からもシートを閉じられるようにする）。
    @ViewBuilder
    private func destination(for tab: Tab) -> some View {
        Group {
            switch tab {
            case .sessions:
                SessionListView(historyStore: historyStore, usageStore: usageStore)
            case .memory:
                MemoryAdminView(memoryStore: memoryStore)
            case .usage:
                UsageDashboardView(usageStore: usageStore, modelSettings: modelSettings)
            case .diagnostics:
                DiagnosticsLogView()
            case .storage:
                StorageUsageView(historyStore: historyStore, usageStore: usageStore)
            case .models:
                ModelSettingsView(store: modelSettings)
            }
        }
        .navigationTitle(tab.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("閉じる") { dismiss() }
            }
        }
    }

    private func reloadSummaries() {
        sessionCount = historyStore.recordCounts().sessions
        monthCostUSD = usageStore.totals().thisMonthUSD
        memoryUpdatedAt = memoryStore.snapshot()?.updatedAt
        diagnosticsUpdatedAt = Self.diagnosticsUpdatedAt()
        overriddenModelCount = modelSettings.overriddenCount
        // 容量だけはディレクトリ走査なので、表示を止めないよう別スレッドで測る（容量タブと同じ形）
        Task.detached(priority: .userInitiated) {
            let report = StorageAudit.measure()
            await MainActor.run { self.storageBytes = report.totalBytes }
        }
    }

    /// 診断ログの最終更新。本文は読まずファイル属性だけ見る（最大 256KB を毎回読まないため）。
    private static func diagnosticsUpdatedAt() -> Date? {
        let values = try? DiagnosticsLog.defaultURL.resourceValues(
            forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }
}

#if DEBUG
/// UIActivityViewController の SwiftUI ラッパ（DEBUG のセッション書き出し専用）。
private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif

/// 推定額の表示（$0.01 未満も潰れないよう桁を切り替える）。
func formattedUSD(_ value: Double) -> String {
    if value == 0 { return "$0.00" }
    if value < 0.01 { return String(format: "$%.4f", value) }
    if value < 1 { return String(format: "$%.3f", value) }
    return String(format: "$%.2f", value)
}
