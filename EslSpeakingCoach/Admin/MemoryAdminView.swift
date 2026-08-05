import SwiftUI

/// 管理画面「記憶」: セッション横断記憶（ローリング記憶ノート）の閲覧とリセット。
/// ノートは 3 本（学習者 / Chobi / Naruko）あり、Picker で切り替える
/// （docs/plans/archive/per-character-memory.md）。
struct MemoryAdminView: View {
    let memoryStore: CharacterMemoryStore

    @State private var scope: MemoryScope = .shared
    @State private var snapshot: CharacterMemoryStore.MemorySnapshot?
    @State private var isConfirmingReset = false
    @State private var isConfirmingResetAll = false

    var body: some View {
        List {
            Section {
                Picker("記憶", selection: $scope) {
                    ForEach(MemoryScope.allCases) { scope in
                        Text(scope.displayName).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            } footer: {
                Text(Self.scopeDescription(scope))
            }

            if let snapshot {
                Section {
                    LabeledContent(
                        "更新日時",
                        value: snapshot.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    let size = Self.size(of: snapshot.text, scope: scope)
                    LabeledContent("語数") {
                        Text("\(size.words) 語 / 約 \(size.limit) 語")
                            .foregroundStyle(size.isOverLimit ? Color.orange : Color.secondary)
                    }
                } footer: {
                    Text("ノートは毎ターンの先頭に積まれるので、長いほど会話ターンの料金が増えます。"
                        + "語数の上限は生成プロンプトでの指示だけで、超えても自動では削られません。")
                }
                Section("記憶ノート") {
                    Text(snapshot.text)
                        .font(.subheadline)
                        .textSelection(.enabled)
                }
                Section {
                    Button("\(scope.displayName)の記憶をリセット", role: .destructive) {
                        isConfirmingReset = true
                    }
                } footer: {
                    Text(Self.resetDescription(scope))
                }
            } else {
                Section {
                    ContentUnavailableView(
                        "記憶はまだありません",
                        systemImage: "brain",
                        description: Text("会話セッションを終えるとここに保存されます"))
                }
            }

            Section {
                Button("すべての記憶をリセット", role: .destructive) {
                    isConfirmingResetAll = true
                }
            } footer: {
                Text("学習者・Chobi・Naruko の 3 本すべてを消して白紙に戻します。会話履歴は消えません。")
            }
        }
        .listStyle(.insetGrouped)
        .onAppear(perform: reload)
        .onChange(of: scope) { _, _ in reload() }
        .confirmationDialog(
            "\(scope.displayName)の記憶をリセットしますか？",
            isPresented: $isConfirmingReset, titleVisibility: .visible
        ) {
            Button("リセット", role: .destructive) {
                memoryStore.reset(scope)
                reload()
            }
            Button("キャンセル", role: .cancel) {}
        }
        .confirmationDialog(
            "すべての記憶をリセットしますか？",
            isPresented: $isConfirmingResetAll, titleVisibility: .visible
        ) {
            Button("リセット", role: .destructive) {
                memoryStore.resetAll()
                reload()
            }
            Button("キャンセル", role: .cancel) {}
        }
    }

    /// ノートの分量。上限は `MemoryScope.wordLimit` = 生成プロンプトがモデルへ指示している値で、
    /// コード側の強制ではない（超えていたら生成プロンプトを詰める合図）。
    struct NoteSize: Equatable {
        let words: Int
        let limit: Int

        var isOverLimit: Bool { words > limit }
    }

    static func size(of text: String, scope: MemoryScope) -> NoteSize {
        NoteSize(words: wordCount(text), limit: scope.wordLimit)
    }

    /// 空白区切りの語数。英数字を 1 文字も含まないトークン（箇条書きの "-" など）は数えない。
    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace)
            .count { $0.contains { $0.isLetter || $0.isNumber } }
    }

    /// どのノートを見ているかの説明（学習者ノートは 2 キャラ共有）。
    private static func scopeDescription(_ scope: MemoryScope) -> String {
        switch scope {
        case .shared:
            return "学習者のことと直近セッションの要約。Chobi と Naruko の両方が覚えています。"
        case .character(let character):
            return "\(character.displayName)自身の身の上や出来事。会話で\(character.displayName)が"
                + "自分について話したことだけが入ります（もともとの人物設定は入りません）。"
        }
    }

    private static func resetDescription(_ scope: MemoryScope) -> String {
        switch scope {
        case .shared:
            return "2 人が学習者と過去の会話を忘れます。キャラ自身の記憶は残ります。会話履歴は消えません。"
        case .character(let character):
            return "学習者のことは覚えたまま、\(character.displayName)自身の身の上が白紙になります。"
                + "会話履歴は消えません。"
        }
    }

    private func reload() {
        snapshot = memoryStore.snapshot(scope)
    }
}
