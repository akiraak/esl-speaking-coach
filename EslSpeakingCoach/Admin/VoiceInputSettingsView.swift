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
    @State private var commitGrace = VoiceInputSettingsStore.defaultCommitGrace
    @State private var window = VoiceInputSettingsStore.defaultWindow
    @State private var measurements: [SpeechSegmentMeasurement] = []

    var body: some View {
        List {
            windowSection
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

    /// 入力の窓（docs/plans/always-on-voice-input.md Phase 3）。
    /// **ここだけで 2026-07 の挙動へ丸ごと戻せる**ようにしておく。
    @ViewBuilder
    private var windowSection: some View {
        Section {
            Picker("入力の窓", selection: windowBinding) {
                ForEach(VoiceInputWindow.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text(window == .always
                 ? "AI が話している間も聞く。読み上げ中はしきい値を厳しくし、"
                   + "こちらが文章を話し始めたら読み上げを止める"
                 : "自分のターンのときだけ聞く。AI のターン中は入力ごと止まるので、"
                   + "声での割り込みはできない（一時停止ボタンとテキスト送信のみ）")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("入力の窓")
        } footer: {
            Text("gpt-live-transcribe（既定）にだけ効きます。"
                 + "gpt-4o-transcribe は常時入力 + 即時割り込みのままです。")
        }
    }

    /// 練習する場所ごとのプリセット。タップでしきい値を丸ごと入れる。
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
                "練習する場所に合わせてしきい値を全項目まとめて入れます（入力の窓・ターンの締め方は対象外）。"
                + "そのあと下で 1 項目ずつ追い込めます（チェックは現在値が一致しているときだけ付きます）。")
        }
    }

    /// ターンをいつ締めて、送るかどうか（送信猶予 + 相槌フィルタの最小語数）。
    /// VAD のしきい値とは層が違う（認識の後で効く）のでセクションを分ける。
    /// docs/plans/always-on-voice-input.md Phase 1 / 3.5、
    /// docs/plans/voice-input-admin-followups.md Step 3。
    @ViewBuilder
    private var turnWordCountSection: some View {
        Section {
            Stepper(value: commitGraceBinding, in: VoiceInputSettingsStore.commitGraceRange, step: 0.1) {
                settingRow(
                    title: "送信猶予",
                    value: VoiceInputSettingsStore.formatCommitGrace(commitGrace),
                    note: "発話が終わってから送るまで待つ時間。"
                        + "長くすると言い淀んでも 1 つのターンになり、応答は遅くなる",
                    isOverridden: commitGrace != VoiceInputSettingsStore.defaultCommitGrace,
                    defaultText: VoiceInputSettingsStore.formatCommitGrace(
                        VoiceInputSettingsStore.defaultCommitGrace))
            }
            Stepper(
                value: turnWordCountBinding,
                in: VoiceInputSettingsStore.minimumTurnWordCountRange
            ) {
                settingRow(
                    title: "ターンにする最小語数",
                    value: "\(minimumTurnWordCount) 語",
                    note: "これ未満の発話は会話ターンにせず、黙って聞き取りに戻る。"
                        + "上げると単語で済ませられなくなる",
                    isOverridden:
                        minimumTurnWordCount != BackchannelFilter.defaultMinimumTurnWordCount,
                    defaultText: "\(BackchannelFilter.defaultMinimumTurnWordCount) 語")
            }
        } header: {
            Text("ターンの締め方")
        } footer: {
            Text(
                "猶予の長短（続きそう / 完結）は標準値からの固定比で決まるので、画面に出すのは標準値だけです。"
                + "0 秒にすると発話終端で即送信（2026-08 より前の挙動）に戻ります。\n"
                + "「Um」「Yes」「Thank you」などの相槌は語数に関わらず落とします。"
                + "最小語数は語彙リストに無い短い発話（「Hello」など）を落とすためのもので、"
                + "AI の読み上げを止めるかどうかの判定には効きません（1 語でも文章なら止めます）。")
        }
    }

    /// しきい値以外の設定行（Stepper のラベル）。`row(_:)` と同じ並びに揃える。
    private func settingRow(
        title: String, value: String, note: String, isOverridden: Bool, defaultText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(value)
                    .monospacedDigit()
                    .foregroundStyle(isOverridden ? ChatTheme.accent : .secondary)
            }
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
            if isOverridden {
                Text("既定は \(defaultText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
        case .assistantTurn:
            var notes = [
                "AI が読み上げている間だけ、上の「発話とみなす音量」と「発話開始の継続」を"
                + "この値へ差し替えます（自分のターンには影響しません）。"
            ]
            let multiplier =
                values[.assistantTurnPeakMultiplier]
                ?? VoiceInputParameter.assistantTurnPeakMultiplier.defaultValue
            let minimumPeak = values[.minimumPeak] ?? VoiceInputParameter.minimumPeak.defaultValue
            notes.append(String(
                format: "いまの設定だと読み上げ中は %.3f になります（%.3f × %.1f）。",
                minimumPeak * multiplier, minimumPeak, multiplier))
            notes.append(
                "読み上げ中は暗騒音の推定が止まるので「暗騒音への倍率」は効きません。"
                + "エコー対策はこの 2 つで行います。")
            // 読み上げ中は「自分のターンより厳しい」が前提。逆転していると、
            // エコーで誤検知しやすい側へ倒れているのに気づけない
            let listeningDuration =
                values[.minimumSpeechDuration] ?? VoiceInputParameter.minimumSpeechDuration.defaultValue
            let assistantDuration =
                values[.assistantTurnSpeechDuration]
                ?? VoiceInputParameter.assistantTurnSpeechDuration.defaultValue
            if assistantDuration < listeningDuration {
                notes.append(
                    "⚠︎ 読み上げ中のほうが自分のターンより緩くなっています"
                    + "（発話開始の継続が短い）。エコーで誤検知しやすくなります。")
            }
            if window == .turnGated {
                notes.append(
                    "⚠︎ いまは入力の窓が「ターン制」なので、この 2 項目は効きません"
                    + "（AI のターン中は入力ごと止まります）。")
            }
            return notes
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
                Text(measurement.outcomeReason ?? "採用")
                    .font(.caption).bold()
                    .foregroundStyle(measurement.isAccepted ? Color.secondary : Color.orange)
                if measurement.startedDuringPlayback == true {
                    // 厳しいしきい値とエコー判定が掛かった対象であることの目印
                    Text("読み上げ中")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
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

    private var windowBinding: Binding<VoiceInputWindow> {
        Binding(
            get: { window },
            set: { newValue in
                store.setWindow(newValue)
                window = store.window
            })
    }

    private var commitGraceBinding: Binding<Double> {
        Binding(
            get: { commitGrace },
            set: { newValue in
                store.setCommitGrace(newValue)
                commitGrace = store.commitGrace
            })
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
            || commitGrace != VoiceInputSettingsStore.defaultCommitGrace
            || window != VoiceInputSettingsStore.defaultWindow
    }

    private func reload() {
        values = Dictionary(
            uniqueKeysWithValues: VoiceInputParameter.allCases.map { ($0, store.value(for: $0)) })
        minimumTurnWordCount = store.minimumTurnWordCount
        commitGrace = store.commitGrace
        window = store.window
        measurements = store.recentMeasurements
    }
}
