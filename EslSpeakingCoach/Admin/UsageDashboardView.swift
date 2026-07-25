import SwiftUI

/// 管理画面「料金」タブ: 推定額のサマリ（今日 / 今月 / 累計）、種別内訳、日別一覧。
/// 表示は記録済みの推定額（記録時の単価表で計算）の合算のみで、再計算はしない。
struct UsageDashboardView: View {
    let usageStore: UsageStore

    @State private var totals = UsageStore.Totals()
    @State private var kindTotals: [UsageStore.KindTotal] = []
    @State private var dailyTotals: [UsageStore.DailyTotal] = []

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    totalTile(title: "今日", value: totals.todayUSD)
                    totalTile(title: "今月", value: totals.thisMonthUSD)
                    totalTile(title: "累計", value: totals.allTimeUSD)
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                .listRowBackground(Color.clear)
            } footer: {
                Text("""
                    各 API レスポンスの usage を記録時の単価で換算した推定値です。\
                    barge-in でキャンセルした分など、記録できない呼び出しがあるため実請求より少なく出ることがあります。
                    """)
            }

            if !kindTotals.isEmpty {
                Section("種別内訳（累計）") {
                    ForEach(kindTotals) { total in
                        LabeledContent(total.kind.label, value: formattedUSD(total.costUSD))
                            .monospacedDigit()
                    }
                }
            }

            if !dailyTotals.isEmpty {
                Section("日別（直近 30 日）") {
                    ForEach(dailyTotals) { total in
                        LabeledContent(
                            total.day.formatted(date: .abbreviated, time: .omitted),
                            value: formattedUSD(total.costUSD))
                        .monospacedDigit()
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .onAppear(perform: reload)
    }

    private func totalTile(title: String, value: Double) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(formattedUSD(value))
                .font(.headline.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(ChatTheme.aiText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(ChatTheme.barBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func reload() {
        totals = usageStore.totals()
        kindTotals = usageStore.kindTotals()
        dailyTotals = usageStore.dailyTotals(days: 30)
    }
}
