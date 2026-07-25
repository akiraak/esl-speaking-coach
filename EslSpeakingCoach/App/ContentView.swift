import SwiftUI

struct ContentView: View {
    private let keychain = KeychainStore()

    @State private var isShowingSettings = false
    @State private var hasAPIKey = false
    @State private var isShowingConversation = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "waveform.circle")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                Text("ESL Speaking Coach")
                    .font(.title)
                Label(hasAPIKey ? "API キー設定済み" : "API キー未設定",
                      systemImage: hasAPIKey ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(hasAPIKey ? .green : .orange)

                Button {
                    isShowingConversation = true
                } label: {
                    Label("会話を始める（案 A プロトタイプ）", systemImage: "mic.circle.fill")
                        .font(.headline)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasAPIKey)
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
            if !hasAPIKey {
                isShowingSettings = true
            }
        }
    }

    private func refreshKeyStatus() {
        hasAPIKey = ((try? keychain.read(account: KeychainStore.anthropicAPIKeyAccount)) ?? nil) != nil
    }
}

#Preview {
    ContentView()
}
