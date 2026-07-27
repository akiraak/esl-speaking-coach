import SwiftUI

/// 管理画面「記憶」タブ: キャラのセッション横断記憶（ローリング記憶ノート）の閲覧とリセット。
struct MemoryAdminView: View {
    let memoryStore: CharacterMemoryStore

    @State private var snapshot: CharacterMemoryStore.MemorySnapshot?
    @State private var isConfirmingReset = false

    var body: some View {
        Group {
            if let snapshot {
                List {
                    Section {
                        LabeledContent(
                            "更新日時",
                            value: snapshot.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    Section("記憶ノート") {
                        Text(snapshot.text)
                            .font(.subheadline)
                            .textSelection(.enabled)
                    }
                    Section {
                        Button("記憶をリセット", role: .destructive) {
                            isConfirmingReset = true
                        }
                    } footer: {
                        Text("キャラが学習者と過去の会話を忘れて白紙に戻ります。会話履歴は消えません。")
                    }
                }
                .listStyle(.insetGrouped)
            } else {
                ContentUnavailableView(
                    "記憶はまだありません",
                    systemImage: "brain",
                    description: Text("会話セッションを終えるとキャラの記憶がここに保存されます"))
            }
        }
        .onAppear(perform: reload)
        .confirmationDialog(
            "キャラの記憶をリセットしますか？", isPresented: $isConfirmingReset, titleVisibility: .visible
        ) {
            Button("リセット", role: .destructive) {
                memoryStore.reset()
                reload()
            }
            Button("キャンセル", role: .cancel) {}
        }
    }

    private func reload() {
        snapshot = memoryStore.snapshot()
    }
}
