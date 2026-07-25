import SwiftUI

/// 管理画面（ヘッダメニューから開く）。会話内容の閲覧と AI 利用料金の確認。
/// 標準コンポーネント中心の簡素な作り。トーク画面に合わせてライト固定。
struct AdminView: View {
    let historyStore: ChatHistoryStore
    let usageStore: UsageStore

    private enum Tab: String, CaseIterable, Identifiable {
        case sessions = "会話"
        case usage = "料金"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab

    init(historyStore: ChatHistoryStore, usageStore: UsageStore, startOnUsage: Bool = false) {
        self.historyStore = historyStore
        self.usageStore = usageStore
        _tab = State(initialValue: startOnUsage ? .usage : .sessions)
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
                case .usage:
                    UsageDashboardView(usageStore: usageStore)
                }
            }
            .navigationTitle("管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.light)
        .tint(ChatTheme.accent)
    }
}

/// 推定額の表示（$0.01 未満も潰れないよう桁を切り替える）。
func formattedUSD(_ value: Double) -> String {
    if value == 0 { return "$0.00" }
    if value < 0.01 { return String(format: "$%.4f", value) }
    if value < 1 { return String(format: "$%.3f", value) }
    return String(format: "$%.2f", value)
}
