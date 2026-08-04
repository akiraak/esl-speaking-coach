import SwiftUI

/// 管理画面「モデル」: 経路ごとに使う Claude のモデルを選ぶ
/// （docs/plans/model-selection-in-admin.md Phase 2。TTS / STT は Phase 3 で足す）。
/// 単価は `AIPricing` から引く（表示のために単価を二重管理しない）。
struct ModelSettingsView: View {
    let store: ModelSettingsStore

    /// 表示中の選択。`ModelSettingsStore` は UserDefaults の薄いラッパで observable ではないので、
    /// 画面側で保持して再描画のトリガにする（保存は都度ストアへ書く）
    @State private var selections: [ClaudeRoute: ClaudeModel] = [:]
    @State private var ttsProvider = TTSProvider.default
    @State private var sttModel = STTModel.default
    /// キーが入っている Keychain アカウント（未設定バッジ用。値そのものは読まない）
    @State private var availableKeyAccounts: Set<String> = []

    var body: some View {
        List {
            ForEach(ClaudeRoute.allCases) { route in
                Section {
                    Picker("モデル", selection: binding(for: route)) {
                        ForEach(ClaudeModel.allCases) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                } header: {
                    Text(route.title)
                } footer: {
                    Text(notes(for: route).joined(separator: "\n"))
                }
            }

            Section {
                Picker("プロバイダ", selection: $ttsProvider) {
                    ForEach(TTSProvider.allCases) { provider in
                        Text(provider.label).tag(provider)
                    }
                }
                .onChange(of: ttsProvider) { _, provider in store.setTTSProvider(provider) }
            } header: {
                Text(AIUsageEvent.Kind.textToSpeech.label)
            } footer: {
                Text(ttsNotes.joined(separator: "\n"))
            }

            Section {
                Picker("モデル", selection: $sttModel) {
                    ForEach(STTModel.allCases) { model in
                        Text(model.label).tag(model)
                    }
                }
                .onChange(of: sttModel) { _, model in store.setSTTModel(model) }
            } header: {
                Text(AIUsageEvent.Kind.speechToText.label)
            } footer: {
                Text(sttNotes.joined(separator: "\n"))
            }

            Section {
                Button("すべて既定に戻す", role: .destructive) {
                    store.resetToDefaults()
                    reload()
                }
                .disabled(!hasOverrides)
            } footer: {
                Text(
                    "会話ターン・読み上げ・音声認識は次のセッション開始から、"
                    + "その他は次のリクエストから反映されます。"
                    + "既定と同じ選択は保存しないので、あとで既定が変わればそのまま追従します。")
            }
        }
        .listStyle(.insetGrouped)
        .onAppear(perform: reload)
    }

    /// 経路ごとの補足（単価 → effort → キャッシュ → 既定との差、の順で出す）。
    private func notes(for route: ClaudeRoute) -> [String] {
        let model = selections[route] ?? route.defaultModel
        var notes = ["\(model.rawValue)・\(AIPricing.tokenPriceDescription(for: model))"]
        if let effort = route.effort {
            notes.append(
                model.supportsEffort
                    ? "effort \(effort)"
                    : "effort \(effort) は送りません（\(model.displayName) は 400 になるため）")
        }
        // キャッシュの注記は言うことがあるときだけ出す（既定のモデルでは黙る）
        if route.usesPromptCache, let cache = cacheNote(route: route, model: model) {
            notes.append(cache)
        }
        if model != route.defaultModel {
            notes.append("既定は \(route.defaultModel.displayName)")
        }
        return notes
    }

    /// 読み上げの補足（単価 → 挙動 → キー未設定 → 既定との差）。
    private var ttsNotes: [String] {
        var notes = ["\(ttsProvider.label)・\(AIPricing.priceDescription(for: ttsProvider))"]
        notes.append(ttsProvider.note)
        if let missing = keyNote(account: ttsProvider.keychainAccount) { notes.append(missing) }
        if ttsProvider != .default { notes.append("既定は \(TTSProvider.default.label)") }
        return notes
    }

    /// 音声認識の補足。モデルで VAD の方式とマイクの設定ごと変わる。
    private var sttNotes: [String] {
        var notes = ["\(sttModel.rawValue)・\(AIPricing.priceDescription(for: sttModel))"]
        notes.append(sttModel.note)
        if let missing = keyNote(account: sttModel.keychainAccount) { notes.append(missing) }
        if sttModel != .default { notes.append("既定は \(STTModel.default.label)") }
        return notes
    }

    /// キー未設定の注意（選ぶこと自体は許す。`.secrets/` に置いて再インストールすれば入る）。
    private func keyNote(account: String) -> String? {
        guard !availableKeyAccounts.contains(account) else { return nil }
        return "API キーが未設定です（.secrets/\(account) を用意して再インストール）"
    }

    /// プロンプトキャッシュの警告。system prompt の長さが分かっていて最小プレフィックスに届かない
    /// ときは断定し、分からない経路でも最小が大きいモデル（haiku-4-5）のときだけ注意を出す。
    /// **どちらもエラーにはならず黙って効かなくなる**ので、画面で気づけるようにしておく。
    private func cacheNote(route: ClaudeRoute, model: ClaudeModel) -> String? {
        let minimum = model.cacheMinimumPromptTokens
        if let tokens = route.approximateSystemPromptTokens {
            guard tokens < minimum else { return nil }
            return "プロンプトキャッシュが効きません（このモデルは \(minimum.formatted()) トークン以上・"
                + "この経路の system prompt は約 \(tokens.formatted()) トークン）"
        }
        // 長さを実測していない経路は、台本（約 2,000 トークン）を目安に最小が大きいモデルだけ注意する
        let yardstick = ClaudeRoute.conversationTurn.approximateSystemPromptTokens ?? 0
        guard minimum > yardstick else { return nil }
        return "system prompt が \(minimum.formatted()) トークン未満だとプロンプトキャッシュが効きません"
    }

    private func binding(for route: ClaudeRoute) -> Binding<ClaudeModel> {
        Binding(
            get: { selections[route] ?? store.model(for: route) },
            set: { model in
                store.setModel(model, for: route)
                selections[route] = model
            })
    }

    private var hasOverrides: Bool {
        ClaudeRoute.allCases.contains { selections[$0] != nil && selections[$0] != $0.defaultModel }
            || ttsProvider != .default || sttModel != .default
    }

    private func reload() {
        selections = Dictionary(
            uniqueKeysWithValues: ClaudeRoute.allCases.map { ($0, store.model(for: $0)) })
        ttsProvider = store.ttsProvider
        sttModel = store.sttModel
        availableKeyAccounts = Self.availableKeyAccounts()
    }

    /// キーが入っているアカウントを集める（有無だけ見る。値は読まないし表示もしない）。
    private static func availableKeyAccounts() -> Set<String> {
        let keychain = KeychainStore()
        let accounts = Set(
            TTSProvider.allCases.map(\.keychainAccount) + STTModel.allCases.map(\.keychainAccount))
        return accounts.filter { account in
            let key = (try? keychain.read(account: account)) ?? nil
            return !(key ?? "").isEmpty
        }
    }
}
