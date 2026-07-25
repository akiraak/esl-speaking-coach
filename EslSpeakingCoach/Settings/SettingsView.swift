import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    private let keychain = KeychainStore()

    @State private var apiKeyInput = ""
    @State private var isKeySaved = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("sk-ant-...", text: $apiKeyInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("保存") { save() }
                        .disabled(trimmedInput.isEmpty)
                } header: {
                    Text("Anthropic API キー")
                } footer: {
                    Text(isKeySaved
                        ? "保存済み。新しいキーを入力して保存すると上書きします。"
                        : "未設定。会話を始めるには API キーが必要です。")
                }

                if isKeySaved {
                    Section {
                        Button("キーを削除", role: .destructive) { deleteKey() }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .onAppear { refresh() }
    }

    private var trimmedInput: String {
        apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func refresh() {
        isKeySaved = ((try? keychain.read(account: KeychainStore.anthropicAPIKeyAccount)) ?? nil) != nil
    }

    private func save() {
        do {
            try keychain.save(trimmedInput, account: KeychainStore.anthropicAPIKeyAccount)
            apiKeyInput = ""
            errorMessage = nil
            refresh()
        } catch {
            errorMessage = "保存に失敗しました: \(error)"
        }
    }

    private func deleteKey() {
        do {
            try keychain.delete(account: KeychainStore.anthropicAPIKeyAccount)
            errorMessage = nil
            refresh()
        } catch {
            errorMessage = "削除に失敗しました: \(error)"
        }
    }
}

#Preview {
    SettingsView()
}
