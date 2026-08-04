import SwiftUI

/// 管理画面「料金」: 推定額のサマリ（今日 / 今月 / 累計）、種別内訳（今月）、日別一覧。
/// 表示は記録済みの推定額（記録時の単価表で計算）の合算のみで、再計算はしない。
/// 種別内訳には**いま選ばれているモデル**と単価（`AIPricing.currentRate`）を併記する。
struct UsageDashboardView: View {
    let usageStore: UsageStore
    let modelSettings: ModelSettingsStore

    @State private var totals = UsageStore.Totals()
    @State private var kindTotals: [UsageStore.KindTotal] = []
    @State private var dailyTotals: [UsageStore.DailyTotal] = []
    /// 描画のたびに UserDefaults を引かないよう、表示時に 1 回だけ読む
    @State private var selection = ModelSelectionSnapshot()

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

            Section {
                ForEach(kindTotals) { total in
                    kindRowView(total)
                }
            } header: {
                Text("種別内訳（今月）")
            } footer: {
                Text("""
                    モデルと単価は管理画面「モデル」でいま選んでいるもの。\
                    推定額は呼び出し時のモデル・記録時の単価で計算・保存されるため、\
                    モデルを切り替えたり単価が改定されたりすると、表示中の単価と過去の記録は一致しません。
                    """)
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

    private func kindRowView(_ total: UsageStore.KindTotal) -> some View {
        let rate = AIPricing.currentRate(for: total.kind, selection: selection)
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(total.kind.label)
                    .font(.subheadline.weight(.semibold))
                Text("\(rate.model)・\(rate.price)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let note = rate.note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(formattedUSD(total.costUSD))
                    .font(.callout)
                    .monospacedDigit()
                Text(percentOfThisMonth(total.costUSD))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// 今月合計に対する割合。合計 0（記録なし・全件 $0）のときは 0% 扱い。
    private func percentOfThisMonth(_ cost: Double) -> String {
        guard totals.thisMonthUSD > 0 else { return "0%" }
        return String(format: "%.1f%%", cost / totals.thisMonthUSD * 100)
    }

    private func reload() {
        selection = modelSettings.snapshot()
        totals = usageStore.totals()
        kindTotals = usageStore.kindTotals()
        dailyTotals = usageStore.dailyTotals(days: 30)
    }
}
