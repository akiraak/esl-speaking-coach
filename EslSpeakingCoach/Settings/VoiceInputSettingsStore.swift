import Foundation

/// 管理画面「音声入力」で調整できるしきい値 1 項目
/// （docs/plans/archive/voice-input-tuning-in-admin.md）。
///
/// 表示名・説明・範囲・刻み・書式・`ClientSpeechEndpointer.Thresholds` への読み書きを
/// ここへ集約し、画面と保存の双方がこれだけを見る（項目を足すときも 1 箇所で済む）。
/// **rawValue は UserDefaults の保存キーなので変えない。**
enum VoiceInputParameter: String, CaseIterable, Identifiable, Sendable {
    case minimumPeak
    case snrRatio
    case unconditionalPeak
    case minimumSpeechDuration
    case silenceDuration
    case lookbackDuration
    case maxSegmentDuration
    case assistantTurnPeakMultiplier
    case assistantTurnSpeechDuration

    var id: String { rawValue }

    /// 画面のセクション分け。
    enum Group: String, CaseIterable, Identifiable, Sendable {
        case level = "音量"
        case time = "時間"
        case assistantTurn = "AI のターン中"
        var id: String { rawValue }

        var parameters: [VoiceInputParameter] {
            VoiceInputParameter.allCases.filter { $0.group == self }
        }
    }

    var group: Group {
        switch self {
        case .minimumPeak, .snrRatio, .unconditionalPeak:
            return .level
        case .minimumSpeechDuration, .silenceDuration, .lookbackDuration, .maxSegmentDuration:
            return .time
        case .assistantTurnPeakMultiplier, .assistantTurnSpeechDuration:
            return .assistantTurn
        }
    }

    var title: String {
        switch self {
        case .minimumPeak: return "発話とみなす音量"
        case .snrRatio: return "暗騒音への倍率"
        case .unconditionalPeak: return "無条件で採用する音量"
        case .minimumSpeechDuration: return "発話開始の継続"
        case .silenceDuration: return "無音での終端"
        case .lookbackDuration: return "語頭の遡り"
        case .maxSegmentDuration: return "強制終端"
        case .assistantTurnPeakMultiplier: return "音量の倍率"
        case .assistantTurnSpeechDuration: return "発話開始の継続"
        }
    }

    /// 何が起きるかの説明（上げたときの効き目を書く）。
    var note: String {
        switch self {
        case .minimumPeak:
            return "静かな部屋ではこの絶対値が閾値になる。上げると物音での誤検知が減り、"
                + "小さい声を取りこぼしやすくなる"
        case .snrRatio:
            return "暗騒音の何倍で発話とみなすか。テレビ等が鳴っている部屋で効く"
        case .unconditionalPeak:
            return "暗騒音の推定が高く出ていても、これだけ大きければ発話とみなす取りこぼし防止の上限"
        case .minimumSpeechDuration:
            return "閾値を超え続けた時間。上げると単発の咳・物音で発火しにくくなる"
        case .silenceDuration:
            return "この長さの無音で発話終端とみなす。下げると応答が速くなり、"
                + "考えるポーズで途中送信されやすくなる"
        case .lookbackDuration:
            return "発話開始判定より前に遡って送る長さ。短いと語頭が欠けて認識精度が落ちる"
        case .maxSegmentDuration:
            return "終端が出ないまま伸び続けたときの打ち切り（持続的な環境音への保険）"
        case .assistantTurnPeakMultiplier:
            return "読み上げ中だけ「発話とみなす音量」に掛ける倍率。"
                + "上げると自分の声のエコーで誤検知しにくくなり、話しかけを取りこぼしやすくなる"
        case .assistantTurnSpeechDuration:
            return "読み上げ中だけ使う発話開始の継続。エコーは単発・短いので、ここが主に効く"
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .minimumPeak: return 0.002...0.05
        case .snrRatio: return 1.5...8
        case .unconditionalPeak: return 0.02...0.2
        case .minimumSpeechDuration: return 0.04...0.5
        case .silenceDuration: return 0.3...2
        case .lookbackDuration: return 0...1.5
        case .maxSegmentDuration: return 15...180
        case .assistantTurnPeakMultiplier: return 1...3
        case .assistantTurnSpeechDuration: return 0.1...0.8
        }
    }

    var step: Double {
        switch self {
        case .minimumPeak: return 0.002
        case .snrRatio: return 0.5
        case .unconditionalPeak: return 0.01
        case .minimumSpeechDuration: return 0.02
        case .silenceDuration, .lookbackDuration: return 0.1
        case .maxSegmentDuration: return 15
        case .assistantTurnPeakMultiplier: return 0.1
        // タップバッファは 0.1 秒（HFP は 0.128 秒）なので、実効的な刻みもこの単位
        case .assistantTurnSpeechDuration: return 0.05
        }
    }

    /// 保存・比較で使う有効桁（Float 経由の誤差と Stepper の加算誤差をここで落とす）。
    var decimals: Int {
        switch self {
        case .minimumPeak, .unconditionalPeak: return 3
        case .snrRatio, .assistantTurnPeakMultiplier: return 1
        case .minimumSpeechDuration, .silenceDuration, .lookbackDuration,
             .assistantTurnSpeechDuration: return 2
        case .maxSegmentDuration: return 0
        }
    }

    /// **既定値はコード側（`ClientSpeechEndpointer.Thresholds()`）が正**。
    /// Float の丸め（0.01 → 0.009999…）を持ち込まないよう有効桁で丸める。
    var defaultValue: Double { normalized(value(in: ClientSpeechEndpointer.Thresholds())) }

    /// 有効桁で丸めてから範囲へ収める（手で書き換えた保存値・範囲を狭めた場合の保険）。
    func clamped(_ value: Double) -> Double {
        min(max(normalized(value), range.lowerBound), range.upperBound)
    }

    func normalized(_ value: Double) -> Double {
        let scale = pow(10, Double(decimals))
        return (value * scale).rounded() / scale
    }

    /// 画面・診断ログ共通の書式。
    func formatted(_ value: Double) -> String {
        switch self {
        case .minimumPeak, .unconditionalPeak:
            return String(format: "%.3f", value)
        case .snrRatio, .assistantTurnPeakMultiplier:
            return String(format: "%.1f×", value)
        case .minimumSpeechDuration, .silenceDuration, .lookbackDuration,
             .assistantTurnSpeechDuration:
            return String(format: "%.2f 秒", value)
        case .maxSegmentDuration:
            return String(format: "%.0f 秒", value)
        }
    }

    func value(in thresholds: ClientSpeechEndpointer.Thresholds) -> Double {
        switch self {
        case .minimumPeak: return Double(thresholds.minimumPeak)
        case .snrRatio: return Double(thresholds.snrRatio)
        case .unconditionalPeak: return Double(thresholds.unconditionalPeak)
        case .minimumSpeechDuration: return thresholds.minimumSpeechDuration
        case .silenceDuration: return thresholds.silenceDuration
        case .lookbackDuration: return thresholds.lookbackDuration
        case .maxSegmentDuration: return thresholds.maxSegmentDuration
        case .assistantTurnPeakMultiplier: return Double(thresholds.assistantTurnPeakMultiplier)
        case .assistantTurnSpeechDuration: return thresholds.assistantTurnMinimumSpeechDuration
        }
    }

    func apply(_ value: Double, to thresholds: inout ClientSpeechEndpointer.Thresholds) {
        switch self {
        case .minimumPeak: thresholds.minimumPeak = Float(value)
        case .snrRatio: thresholds.snrRatio = Float(value)
        case .unconditionalPeak: thresholds.unconditionalPeak = Float(value)
        case .minimumSpeechDuration: thresholds.minimumSpeechDuration = value
        case .silenceDuration: thresholds.silenceDuration = value
        case .lookbackDuration: thresholds.lookbackDuration = value
        case .maxSegmentDuration: thresholds.maxSegmentDuration = value
        case .assistantTurnPeakMultiplier: thresholds.assistantTurnPeakMultiplier = Float(value)
        case .assistantTurnSpeechDuration: thresholds.assistantTurnMinimumSpeechDuration = value
        }
    }
}

/// 練習する場所ごとのしきい値のプリセット（docs/plans/archive/voice-input-tuning-in-admin.md Phase 5）。
/// 7 項目を個別に動かすのは最終手段で、普段はここから 1 タップで丸ごと入れる。
///
/// 暗騒音が上がるほど「絶対値の下限」と「暗騒音への倍率」を上げ、単発の物音を弾くために
/// 発話開始の継続も伸ばす。騒がしい場所は無音による終端が出にくいので強制終端を短くする。
/// **どれもコード既定とは一致させない**（既定は「すべて既定に戻す」で戻すもので、
/// プリセットは選択状態を持たず、現在値が一致していればチェックが付くだけ）。
enum VoiceInputPreset: String, CaseIterable, Identifiable, Sendable {
    case quietRoom = "静かな部屋"
    case livingNoise = "生活音のある部屋"
    case outdoors = "外・カフェ"

    var id: String { rawValue }

    var note: String {
        switch self {
        case .quietRoom:
            return "自宅の静かな部屋。既定より少しだけ厳しくして、衣擦れ・キーボードでの誤検知を減らす"
        case .livingNoise:
            return "テレビや家族の声がある部屋。暗騒音より明確に大きい声だけを通す"
        case .outdoors:
            return "屋外・カフェ。常に暗騒音が高い前提で、下限と倍率を上げて短めに区切る"
        }
    }

    /// **全項目を持つ**（一部でも欠けると、プリセット適用でその項目が黙って既定へ戻る）。
    /// 「AI のターン中」の 2 項目は、騒がしい場所ほど読み上げ音量も上がる ＝ エコーも増える、
    /// という関係で出し分ける（docs/plans/voice-input-admin-followups.md Step 2）。
    var values: [VoiceInputParameter: Double] {
        switch self {
        case .quietRoom:
            return [
                .minimumPeak: 0.012, .snrRatio: 3.0, .unconditionalPeak: 0.05,
                .minimumSpeechDuration: 0.16, .silenceDuration: 0.8,
                .lookbackDuration: 0.5, .maxSegmentDuration: 60,
                .assistantTurnPeakMultiplier: 1.5, .assistantTurnSpeechDuration: 0.3,
            ]
        case .livingNoise:
            return [
                .minimumPeak: 0.016, .snrRatio: 4.0, .unconditionalPeak: 0.06,
                .minimumSpeechDuration: 0.2, .silenceDuration: 0.8,
                .lookbackDuration: 0.5, .maxSegmentDuration: 45,
                .assistantTurnPeakMultiplier: 1.5, .assistantTurnSpeechDuration: 0.3,
            ]
        case .outdoors:
            return [
                .minimumPeak: 0.024, .snrRatio: 5.0, .unconditionalPeak: 0.08,
                .minimumSpeechDuration: 0.24, .silenceDuration: 0.7,
                .lookbackDuration: 0.5, .maxSegmentDuration: 30,
                .assistantTurnPeakMultiplier: 2.0, .assistantTurnSpeechDuration: 0.35,
            ]
        }
    }

    /// 既定との差だけを並べた 1 行（画面の補足用）。
    var differenceSummary: String {
        VoiceInputParameter.allCases
            .filter { values[$0] != $0.defaultValue }
            .map { "\($0.title) \($0.formatted(values[$0] ?? $0.defaultValue))" }
            .joined(separator: " / ")
    }

    func value(for parameter: VoiceInputParameter) -> Double {
        values[parameter] ?? parameter.defaultValue
    }
}

/// 音声入力のしきい値の保存（管理画面「音声入力」）と、調整の手がかりにする直近セグメントの実測。
/// 保存は UserDefaults（端末内）。**同じ画面でしか使わないので型は分けない**。
///
/// `ModelSettingsStore` と同じ規約で、**既定値はコード側が正**（`VoiceInputParameter.defaultValue`）。
/// ここは既定と違うときだけ保存するので、既定を変えれば明示的に触っていない項目は追従する。
/// 値は**次のセッション開始時**に `ChatRoomStore.launchSession` が読む（セッション中は変わらない）。
@MainActor
final class VoiceInputSettingsStore {
    static let shared = VoiceInputSettingsStore()

    /// 実測を残す件数（調整に使う直近ぶんだけ。UserDefaults に置くので上限を持つ）
    static let measurementLimit = 20
    static let measurementsKey = "voiceInput.recentSegments"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func key(for parameter: VoiceInputParameter) -> String {
        "voiceInput.\(parameter.rawValue)"
    }

    // MARK: - しきい値

    func value(for parameter: VoiceInputParameter) -> Double {
        guard let stored = defaults.object(forKey: Self.key(for: parameter)) as? Double else {
            return parameter.defaultValue
        }
        return parameter.clamped(stored)
    }

    func setValue(_ value: Double, for parameter: VoiceInputParameter) {
        let clamped = parameter.clamped(value)
        guard clamped != self.value(for: parameter) else { return }
        if clamped == parameter.defaultValue {
            defaults.removeObject(forKey: Self.key(for: parameter))
        } else {
            defaults.set(clamped, forKey: Self.key(for: parameter))
        }
        DiagnosticsLog.record(
            "voiceInput: \(parameter.title) → \(parameter.formatted(clamped))")
    }

    /// 既定から変えている項目。
    var overriddenParameters: [VoiceInputParameter] {
        VoiceInputParameter.allCases.filter { value(for: $0) != $0.defaultValue }
    }

    var overriddenCount: Int { overriddenParameters.count }

    /// しきい値以外も含めて、既定から動かしているものがあるか（画面の「戻す」ボタン用）。
    var hasAnyOverride: Bool {
        overriddenCount > 0
            || minimumTurnWordCount != BackchannelFilter.defaultMinimumTurnWordCount
            || commitGrace != Self.defaultCommitGrace
            || window != Self.defaultWindow
    }

    func resetToDefaults() {
        guard hasAnyOverride else { return }
        for parameter in VoiceInputParameter.allCases {
            defaults.removeObject(forKey: Self.key(for: parameter))
        }
        defaults.removeObject(forKey: Self.minimumTurnWordCountKey)
        defaults.removeObject(forKey: Self.commitGraceKey)
        defaults.removeObject(forKey: Self.windowKey)
        DiagnosticsLog.record("voiceInput: すべて既定に戻した")
    }

    // MARK: - 入力の窓（docs/plans/always-on-voice-input.md Phase 3）

    static let windowKey = "voiceInput.window"
    /// **既定はコード側が正**。常時入力が合わないと分かったらここを変える
    static var defaultWindow: VoiceInputWindow { .always }

    /// AI のターン中も入力を開けるか。`turnGated` にすると 2026-07 の挙動
    /// （自分のターンだけ聞く / 音声での割り込みなし）へ丸ごと戻る。
    var window: VoiceInputWindow {
        guard let raw = defaults.string(forKey: Self.windowKey),
              let stored = VoiceInputWindow(rawValue: raw) else { return Self.defaultWindow }
        return stored
    }

    func setWindow(_ value: VoiceInputWindow) {
        guard value != window else { return }
        if value == Self.defaultWindow {
            defaults.removeObject(forKey: Self.windowKey)
        } else {
            defaults.set(value.rawValue, forKey: Self.windowKey)
        }
        DiagnosticsLog.record("voiceInput: 入力の窓 → \(value.rawValue)")
    }

    // MARK: - 送信猶予（docs/plans/voice-input-admin-followups.md Step 3）

    static let commitGraceKey = "voiceInput.commitGrace"
    /// 0 = 従来どおりの即送信 〜 2.5 秒。
    static let commitGraceRange = 0.0...2.5
    /// **既定はコード側が正**（`TurnCommitGrace()` の標準値）。
    static var defaultCommitGrace: Double { TurnCommitGrace().standard }

    /// 発話終端から Claude へ投げるまでの猶予（標準値）。長短は標準からの固定比で導くので、
    /// **画面に出すのはこの 1 つだけ**。
    var commitGrace: Double {
        guard let stored = defaults.object(forKey: Self.commitGraceKey) as? Double else {
            return Self.defaultCommitGrace
        }
        return Self.normalizedCommitGrace(stored)
    }

    func setCommitGrace(_ value: Double) {
        let clamped = Self.normalizedCommitGrace(value)
        guard clamped != commitGrace else { return }
        if clamped == Self.defaultCommitGrace {
            defaults.removeObject(forKey: Self.commitGraceKey)
        } else {
            defaults.set(clamped, forKey: Self.commitGraceKey)
        }
        DiagnosticsLog.record("voiceInput: 送信猶予 → \(Self.formatCommitGrace(clamped))")
    }

    /// セッションへ渡す送信猶予（標準値だけ差し替え、長短の比は既定のまま）。
    func commitGraceSettings() -> TurnCommitGrace {
        var grace = TurnCommitGrace()
        grace.standard = commitGrace
        return grace
    }

    /// Stepper の加算誤差を落としてから範囲へ収める。
    static func normalizedCommitGrace(_ value: Double) -> Double {
        let rounded = (value * 100).rounded() / 100
        return min(max(rounded, commitGraceRange.lowerBound), commitGraceRange.upperBound)
    }

    static func formatCommitGrace(_ value: Double) -> String {
        value == 0 ? "0 秒（即送信）" : String(format: "%.1f 秒", value)
    }

    // MARK: - 最小語数（相槌フィルタ）

    static let minimumTurnWordCountKey = "voiceInput.minimumTurnWordCount"
    /// 1 = 語数で切らない（相槌の語彙だけで判定する）〜 5。
    static let minimumTurnWordCountRange = 1...5

    /// 会話ターンとして送るのに必要な最小語数
    /// （docs/plans/always-on-voice-input.md Phase 3.5）。**既定はコード側が正**。
    var minimumTurnWordCount: Int {
        guard let stored = defaults.object(forKey: Self.minimumTurnWordCountKey) as? Int else {
            return BackchannelFilter.defaultMinimumTurnWordCount
        }
        return min(
            max(stored, Self.minimumTurnWordCountRange.lowerBound),
            Self.minimumTurnWordCountRange.upperBound)
    }

    func setMinimumTurnWordCount(_ value: Int) {
        let clamped = min(
            max(value, Self.minimumTurnWordCountRange.lowerBound),
            Self.minimumTurnWordCountRange.upperBound)
        guard clamped != minimumTurnWordCount else { return }
        if clamped == BackchannelFilter.defaultMinimumTurnWordCount {
            defaults.removeObject(forKey: Self.minimumTurnWordCountKey)
        } else {
            defaults.set(clamped, forKey: Self.minimumTurnWordCountKey)
        }
        DiagnosticsLog.record("voiceInput: ターンにする最小語数 → \(clamped) 語")
    }

    // MARK: - プリセット

    /// 現在値が一致しているプリセット（無ければ nil = 既定 or 手で調整した状態）。
    var matchingPreset: VoiceInputPreset? {
        VoiceInputPreset.allCases.first { preset in
            VoiceInputParameter.allCases.allSatisfy {
                value(for: $0) == preset.value(for: $0)
            }
        }
    }

    /// プリセットの値を全項目へ入れる（既定と同じ項目は保存されないので、あとで既定が
    /// 変わればその項目は追従する）。
    func apply(_ preset: VoiceInputPreset) {
        for parameter in VoiceInputParameter.allCases {
            setValue(preset.value(for: parameter), for: parameter)
        }
        DiagnosticsLog.record("voiceInput: プリセット「\(preset.rawValue)」を適用")
    }

    /// クライアント VAD（live 経路の発話検知）へ渡すしきい値。
    func thresholds() -> ClientSpeechEndpointer.Thresholds {
        var thresholds = ClientSpeechEndpointer.Thresholds()
        for parameter in VoiceInputParameter.allCases {
            parameter.apply(value(for: parameter), to: &thresholds)
        }
        return thresholds
    }

    /// 認識後の棄却（レベルゲート）へ渡すしきい値。**音量の 3 項目は検知側と同じ値を共有する**
    /// （既定値も同一で、コード上も「実機調整値を流用」する関係にある）。
    /// `minimumSampleCount` は画面に出さないので既定のまま。
    func levelGateThresholds() -> SpeechLevelGate.Thresholds {
        var gate = SpeechLevelGate.Thresholds()
        gate.minimumPeak = Float(value(for: .minimumPeak))
        gate.snrRatio = Float(value(for: .snrRatio))
        gate.unconditionalPeak = Float(value(for: .unconditionalPeak))
        return gate
    }

    /// セッション開始時の診断ログ 1 行（既定のままなら「既定」）。
    /// プリセットに一致していれば名前も添える（あとから「どの環境設定のセッションか」を辿る）。
    var diagnosticsSummary: String {
        var parts: [String] = []
        let overrides = overriddenParameters
        if !overrides.isEmpty {
            let values = overrides
                .map { "\($0.rawValue)=\($0.formatted(value(for: $0)))" }
                .joined(separator: " ")
            parts.append(matchingPreset.map { "preset=\($0.rawValue) \(values)" } ?? values)
        }
        if minimumTurnWordCount != BackchannelFilter.defaultMinimumTurnWordCount {
            parts.append("minimumTurnWordCount=\(minimumTurnWordCount)")
        }
        if commitGrace != Self.defaultCommitGrace {
            parts.append("commitGrace=\(Self.formatCommitGrace(commitGrace))")
        }
        if window != Self.defaultWindow {
            parts.append("window=\(window.rawValue)")
        }
        return parts.isEmpty ? "既定" : parts.joined(separator: " ")
    }

    // MARK: - 直近の実測

    /// 新しい順・最大 `measurementLimit` 件。壊れていたら黙って捨てる（調整の参考値なので）。
    var recentMeasurements: [SpeechSegmentMeasurement] {
        guard let data = defaults.data(forKey: Self.measurementsKey),
              let decoded = try? JSONDecoder().decode([SpeechSegmentMeasurement].self, from: data)
        else { return [] }
        return decoded
    }

    func record(_ measurement: SpeechSegmentMeasurement) {
        let updated = ([measurement] + recentMeasurements).prefix(Self.measurementLimit)
        guard let data = try? JSONEncoder().encode(Array(updated)) else { return }
        defaults.set(data, forKey: Self.measurementsKey)
    }

    func clearMeasurements() {
        defaults.removeObject(forKey: Self.measurementsKey)
    }
}
