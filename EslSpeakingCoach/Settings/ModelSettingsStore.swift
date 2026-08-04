import Foundation

/// 管理画面の選択を 1 回読み出した結果。料金画面の描画と診断ログで使い回す
/// （描画のたびに UserDefaults を引かない・1 セッション内で表示がぶれない）。
struct ModelSelectionSnapshot: Sendable {
    var claudeModels: [ClaudeRoute: ClaudeModel] = [:]
    var ttsProvider: TTSProvider = .default
    var sttModel: STTModel = .default

    func model(for route: ClaudeRoute) -> ClaudeModel {
        claudeModels[route] ?? route.defaultModel
    }

    /// 診断ログ 1 行ぶん。あとから「どの構成でのセッションだったか」を辿れるようにする。
    /// キーは課金経路の rawValue（保存キー・料金画面と同じ語彙）。
    var diagnosticsSummary: String {
        let claude = ClaudeRoute.allCases
            .map { "\($0.kind.rawValue)=\(model(for: $0).rawValue)" }
            .joined(separator: " ")
        return claude
            + " \(AIUsageEvent.Kind.textToSpeech.rawValue)=\(ttsProvider.modelDescription)"
            + " \(AIUsageEvent.Kind.speechToText.rawValue)=\(sttModel.rawValue)"
    }
}

/// 経路ごとに使うモデルの選択（管理画面「モデル」。docs/plans/model-selection-in-admin.md）。
/// 保存は UserDefaults（端末内）。
///
/// **既定値はコード側（`ClaudeRoute.defaultModel` / `TTSProvider.default` / `STTModel.default`）が正**で、
/// ここは既定と違うときだけ保存する。こうしておくと既定を変えたときに、
/// 明示的に選んでいない経路は自動で追従する。
@MainActor
final class ModelSettingsStore {
    static let shared = ModelSettingsStore()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 保存キー。課金経路の rawValue に揃える（Phase 3 の TTS / STT も同じ形で足せる）。
    static func key(for route: ClaudeRoute) -> String { "model.\(route.kind.rawValue)" }

    /// 未設定・未知の値（廃止したモデル名が残っている等）はコード既定へフォールバックする。
    func model(for route: ClaudeRoute) -> ClaudeModel {
        guard let raw = defaults.string(forKey: Self.key(for: route)),
              let model = ClaudeModel(rawValue: raw)
        else { return route.defaultModel }
        return model
    }

    func setModel(_ model: ClaudeModel, for route: ClaudeRoute) {
        guard model != self.model(for: route) else { return }
        if model == route.defaultModel {
            defaults.removeObject(forKey: Self.key(for: route))
        } else {
            defaults.set(model.rawValue, forKey: Self.key(for: route))
        }
        DiagnosticsLog.record("model: \(route.title) → \(model.rawValue)")
    }

    // MARK: - 音声（TTS / STT）

    /// 保存キーは Claude 側と同じ「課金経路の rawValue」形式で揃える。
    static let ttsKey = "model.\(AIUsageEvent.Kind.textToSpeech.rawValue)"
    static let sttKey = "model.\(AIUsageEvent.Kind.speechToText.rawValue)"

    /// 読み上げのプロバイダ。**セッション開始時と再読み上げの生成時に読む**（途中では変わらない）。
    var ttsProvider: TTSProvider {
        guard let raw = defaults.string(forKey: Self.ttsKey),
              let provider = TTSProvider(rawValue: raw)
        else { return .default }
        return provider
    }

    func setTTSProvider(_ provider: TTSProvider) {
        guard provider != ttsProvider else { return }
        if provider == .default {
            defaults.removeObject(forKey: Self.ttsKey)
        } else {
            defaults.set(provider.rawValue, forKey: Self.ttsKey)
        }
        DiagnosticsLog.record("model: 読み上げ (TTS) → \(provider.rawValue)")
    }

    /// 音声認識のモデル。**セッション開始時に読む**（接続クライアントとマイクの設定ごと決まる）。
    var sttModel: STTModel {
        guard let raw = defaults.string(forKey: Self.sttKey),
              let model = STTModel(rawValue: raw)
        else { return .default }
        return model
    }

    func setSTTModel(_ model: STTModel) {
        guard model != sttModel else { return }
        if model == .default {
            defaults.removeObject(forKey: Self.sttKey)
        } else {
            defaults.set(model.rawValue, forKey: Self.sttKey)
        }
        DiagnosticsLog.record("model: 音声認識 (STT) → \(model.rawValue)")
    }

    // MARK: - 既定との差

    /// 全経路をコード既定へ戻す。
    func resetToDefaults() {
        guard overriddenCount > 0 else { return }
        for route in ClaudeRoute.allCases {
            defaults.removeObject(forKey: Self.key(for: route))
        }
        defaults.removeObject(forKey: Self.ttsKey)
        defaults.removeObject(forKey: Self.sttKey)
        DiagnosticsLog.record("model: 全経路を既定に戻した")
    }

    /// いまの選択をまとめて読み出す。
    func snapshot() -> ModelSelectionSnapshot {
        ModelSelectionSnapshot(
            claudeModels: Dictionary(
                uniqueKeysWithValues: ClaudeRoute.allCases.map { ($0, model(for: $0)) }),
            ttsProvider: ttsProvider,
            sttModel: sttModel)
    }

    /// 既定から変えている Claude 経路。
    var overriddenRoutes: [ClaudeRoute] {
        ClaudeRoute.allCases.filter { model(for: $0) != $0.defaultModel }
    }

    /// 既定から変えている経路の数（音声 2 経路を含む。管理画面ルートのサマリ用）。
    var overriddenCount: Int {
        overriddenRoutes.count + (ttsProvider != .default ? 1 : 0) + (sttModel != .default ? 1 : 0)
    }
}
