import SwiftUI

struct ContentView: View {
    private let keychain = KeychainStore()

    @State private var isShowingSettings = false
    @State private var hasAnthropicKey = false
    @State private var hasOpenAIKey = false
    @State private var isShowingConversation = false

    private var hasAnyKey: Bool { hasAnthropicKey || hasOpenAIKey }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "waveform.circle")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                Text("ESL Speaking Coach")
                    .font(.title)
                keyStatusLabel("Anthropic", isSet: hasAnthropicKey)
                keyStatusLabel("OpenAI", isSet: hasOpenAIKey)

                Button {
                    isShowingConversation = true
                } label: {
                    Label("会話を始める（プロトタイプ）", systemImage: "mic.circle.fill")
                        .font(.headline)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasAnyKey)
            }
            .navigationDestination(isPresented: $isShowingConversation) {
                ConversationView()
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingSettings, onDismiss: refreshKeyStatus) {
            SettingsView()
        }
        .onAppear {
            refreshKeyStatus()
            #if DEBUG
            if DebugLaunchArguments.shouldOpenConversation {
                isShowingConversation = true
                return
            }
            #endif
            if !hasAnyKey {
                isShowingSettings = true
            }
        }
    }

    private func keyStatusLabel(_ name: String, isSet: Bool) -> some View {
        Label("\(name) キー\(isSet ? "設定済み" : "未設定")",
              systemImage: isSet ? "checkmark.circle" : "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(isSet ? .green : .orange)
    }

    private func refreshKeyStatus() {
        hasAnthropicKey = ((try? keychain.read(account: KeychainStore.anthropicAPIKeyAccount)) ?? nil) != nil
        hasOpenAIKey = ((try? keychain.read(account: KeychainStore.openAIAPIKeyAccount)) ?? nil) != nil
    }
}

#Preview {
    ContentView()
}
