import SwiftUI

/// 管理画面「音声入力」: 発話の検知（クライアント VAD）と認識後の棄却（レベルゲート）の
/// しきい値を実機で追い込む（docs/plans/archive/voice-input-tuning-in-admin.md）。
/// 反映は**次のセッションから**。調整の手がかりに直近セグメントの実測を下に並べる。
struct VoiceInputSettingsView: View {
    let store: VoiceInputSettingsStore

    /// 表示中の値。`VoiceInputSettingsStore` は UserDefaults の薄いラッパで observable では
    /// ないので、画面側で保持して再描画のトリガにする（保存は都度ストアへ書く）
    @State private var values: [VoiceInputParameter: Double] = [:]
    @State private var minimumTurnWordCount = BackchannelFilter.defaultMinimumTurnWordCount
    @State private var measurements: [SpeechSegmentMeasurement] = []

    var body: some View {
        List {
            presetSection

            ForEach(VoiceInputParameter.Group.allCases) { group in
                Section {
                    ForEach(group.parameters) { parameter in
                        Stepper(
                            value: binding(for: parameter),
                            in: parameter.range,
                            step: parameter.step
                        ) {
                            row(parameter)
                        }
                    }
                } header: {
                    Text(group.rawValue)
                } footer: {
                    Text(footer(for: group).joined(separator: "\n"))
                }
            }

            turnWordCountSection

            Section {
                Button("すべて既定に戻す", role: .destructive) {
                    store.resetToDefaults()
                    reload()
                }
                .disabled(!hasOverrides)
            } footer: {
                Text(
                    "次のセッション開始から反映されます。"
                    + "既定と同じ値は保存しないので、あとで既定が変わればそのまま追従します。")
            }

            measurementSection
        }
        .listStyle(.insetGrouped)
        .onAppear(perform: reload)
    }

    /// 練習する場所ごとのプリセット。タップで 7 項目を丸ごと入れる。
    /// 選択状態は持たず、**現在値が一致していればチェックを付ける**だけ
    /// （手で 1 項目でも動かせばチェックは消える）。
    @ViewBuilder
    private var presetSection: some View {
        let matching = matchingPreset
        Section {
            ForEach(VoiceInputPreset.allCases) { preset in
                Button {
                    store.apply(preset)
                    reload()
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.rawValue)
                                .foregroundStyle(.primary)
                            Text(preset.note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if preset == matching {
                            Image(systemName: "checkmark")
                                .foregroundStyle(ChatTheme.accent)
                        }
                    }
                    // 既定のボタンスタイルだとラベル全体がアクセント色に染まって説明文まで読みにくい
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("プリセット")
        } footer: {
            Text(
                "練習する場所に合わせて 7 項目をまとめて入れます。"
                + "そのあと下で 1 項目ずつ追い込めます（チェックは現在値が一致しているときだけ付きます）。")
        }
    }

    /// 相槌フィルタの最小語数（docs/plans/always-on-voice-input.md Phase 3.5）。
    /// しきい値（VAD）とは別の層なので、プリセットにも「すべて既定に戻す」の対象にも
    /// 入るが、セクションは分ける。
    @ViewBuilder
    private var turnWordCountSection: some View {
        let isOverridden = minimumTurnWordCount != BackchannelFilter.defaultMinimumTurnWordCount
        Section {
            Stepper(
                value: turnWordCountBinding,
                in: VoiceInputSettingsStore.minimumTurnWordCountRange
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("ターンにする最小語数")
                        Spacer()
                        Text("\(minimumTurnWordCount) 語")
                            .monospacedDigit()
                            .foregroundStyle(isOverridden ? ChatTheme.accent : .secondary)
                    }
                    Text("これ未満の発話は会話ターンにせず、黙って聞き取りに戻る。"
                         + "上げると単語で済ませられなくなる")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if isOverridden {
                        Text("既定は \(BackchannelFilter.defaultMinimumTurnWordCount) 語")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("相槌フィルタ")
        } footer: {
            Text(
                "「Um」「Yes」「Thank you」などの相槌は語数に関わらず落とします。"
                + "ここは語彙リストに無い短い発話（「Hello」など）を落とすための語数です。"
                + "1 語にすると語数では落とさなくなります。"
                + "AI の読み上げを止めるかどうかの判定には効きません（1 語でも文章なら止めます）。")
        }
    }

    /// 1 項目の行（Stepper のラベル）。現在値 → 説明 → 既定との差、の順。
    private func row(_ parameter: VoiceInputParameter) -> some View {
        let value = values[parameter] ?? parameter.defaultValue
        let isOverridden = value != parameter.defaultValue
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(parameter.title)
                Spacer()
                Text(parameter.formatted(value))
                    .monospacedDigit()
                    .foregroundStyle(isOverridden ? ChatTheme.accent : .secondary)
            }
            Text(parameter.note)
                .font(.caption)
                .foregroundStyle(.secondary)
            if isOverridden {
                Text("既定は \(parameter.formatted(parameter.defaultValue))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// グループごとの補足（どこに効くか → 効かない経路 → 危ない組み合わせ）。
    private func footer(for group: VoiceInputParameter.Group) -> [String] {
        switch group {
        case .level:
            var notes = ["発話の検知と、認識後の棄却（暗騒音と大差ないセグメントを捨てる）の両方に効きます。"]
            notes.append("閾値は 暗騒音 × 倍率 を「発話とみなす音量」と「無条件で採用する音量」で挟んだ値です。")
            let minimumPeak = values[.minimumPeak] ?? VoiceInputParameter.minimumPeak.defaultValue
            let unconditional =
                values[.unconditionalPeak] ?? VoiceInputParameter.unconditionalPeak.defaultValue
            if unconditional < minimumPeak {
                notes.append(
                    "⚠︎ 無条件で採用する音量が発話とみなす音量を下回っています（下限が効きません）。")
            }
            return notes
        case .time:
            return [
                "gpt-live-transcribe（既定）のクライアント VAD にだけ効きます。"
                + "gpt-4o-transcribe はサーバ VAD なので影響しません。"
            ]
        }
    }

    /// 直近セグメントの実測。数値の意味が分かるよう会話ログと同じ並び（peak / mean / floor / 比）で出す。
    @ViewBuilder
    private var measurementSection: some View {
        Section {
            if measurements.isEmpty {
                Text("まだありません（音声入力で 1 セッション話すと溜まります）")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(measurements.enumerated()), id: \.offset) { _, measurement in
                    measurementRow(measurement)
                }
            }
        } header: {
            HStack {
                Text("直近のセグメント")
                Spacer()
                Button("消す") {
                    store.clearMeasurements()
                    measurements = []
                }
                .font(.caption)
                .disabled(measurements.isEmpty)
            }
        } footer: {
            Text(
                "peak がセグメント区間の音量の最大値、floor が暗騒音の推定。"
                + "本人の発話が採用され、物音が棄却される値を探します。最大 "
                + "\(VoiceInputSettingsStore.measurementLimit) 件。")
        }
    }

    private func measurementRow(_ measurement: SpeechSegmentMeasurement) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(measurement.verdict.reason ?? "採用")
                    .font(.caption).bold()
                    .foregroundStyle(measurement.verdict.isAccepted ? Color.secondary : Color.orange)
                Spacer()
                Text(measurement.measuredAt.formatted(date: .omitted, time: .standard))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(measurement.levels?.summaryLine ?? "レベル計測なし")
                .font(.caption)
                .monospacedDigit()
            Text(measurement.transcript.isEmpty ? "（認識テキストなし）" : "「\(measurement.transcript)」")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func binding(for parameter: VoiceInputParameter) -> Binding<Double> {
        Binding(
            get: { values[parameter] ?? store.value(for: parameter) },
            set: { newValue in
                store.setValue(newValue, for: parameter)
                // 丸め・範囲の補正が入るのでストアの値を読み直す
                values[parameter] = store.value(for: parameter)
            })
    }

    /// 一致しているプリセット。ストアではなく**表示中の値**から見るので、
    /// Stepper を 1 つ動かした瞬間にチェックが消える。
    private var matchingPreset: VoiceInputPreset? {
        VoiceInputPreset.allCases.first { preset in
            VoiceInputParameter.allCases.allSatisfy {
                (values[$0] ?? $0.defaultValue) == preset.value(for: $0)
            }
        }
    }

    private var turnWordCountBinding: Binding<Int> {
        Binding(
            get: { minimumTurnWordCount },
            set: { newValue in
                store.setMinimumTurnWordCount(newValue)
                minimumTurnWordCount = store.minimumTurnWordCount
            })
    }

    private var hasOverrides: Bool {
        VoiceInputParameter.allCases.contains { values[$0] != nil && values[$0] != $0.defaultValue }
            || minimumTurnWordCount != BackchannelFilter.defaultMinimumTurnWordCount
    }

    private func reload() {
        values = Dictionary(
            uniqueKeysWithValues: VoiceInputParameter.allCases.map { ($0, store.value(for: $0)) })
        minimumTurnWordCount = store.minimumTurnWordCount
        measurements = store.recentMeasurements
    }
}
