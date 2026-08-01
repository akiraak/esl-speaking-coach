import SwiftUI
#if DEBUG
import UIKit
#endif

/// 管理画面（ヘッダメニューから開く）。会話内容の閲覧・キャラの記憶・AI 利用料金の確認。
/// 標準コンポーネント中心の簡素な作り。トーク画面に合わせてライト固定。
struct AdminView: View {
    let historyStore: ChatHistoryStore
    let usageStore: UsageStore
    let memoryStore: CharacterMemoryStore

    enum Tab: String, CaseIterable, Identifiable {
        case sessions = "会話"
        case memory = "記憶"
        case usage = "料金"
        case diagnostics = "診断"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab
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
        memoryStore: CharacterMemoryStore, initialTab: Tab = .sessions
    ) {
        self.historyStore = historyStore
        self.usageStore = usageStore
        self.memoryStore = memoryStore
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("表示", selection: $tab) {
                    ForEach(Tab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                switch tab {
                case .sessions:
                    SessionListView(historyStore: historyStore, usageStore: usageStore)
                case .memory:
                    MemoryAdminView(memoryStore: memoryStore)
                case .usage:
                    UsageDashboardView(usageStore: usageStore)
                case .diagnostics:
                    DiagnosticsLogView()
                }
            }
            .navigationTitle("管理")
            .navigationBarTitleDisplayMode(.inline)
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
            #if DEBUG
            .sheet(item: $exportFile) { file in
                ActivityShareSheet(items: [file.url])
            }
            #endif
        }
        .preferredColorScheme(.light)
        .tint(ChatTheme.accent)
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
