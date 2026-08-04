import SwiftUI
import UIKit

/// 管理画面「診断」: クラッシュ調査用の追記ログ（docs/plans/end-session-crash.md Phase 0）。
/// 前回起動ぶんも残っているので、落ちた後に再起動してからここを読む。
struct DiagnosticsLogView: View {
    /// 画面に出す行数の上限（コピーは全文）。長すぎる本文の描画で画面が固まらないようにする
    static let displayLineLimit = 400

    @State private var text = ""
    @State private var isConfirmingClear = false
    @State private var didCopy = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    UIPasteboard.general.string = text
                    didCopy = true
                } label: {
                    Label(didCopy ? "コピーしました" : "全文をコピー", systemImage: "doc.on.doc")
                }
                Spacer()
                Button("再読み込み", action: reload)
                Button("クリア", role: .destructive) { isConfirmingClear = true }
            }
            .font(.subheadline)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 8)

            if text.isEmpty {
                ContentUnavailableView(
                    "ログはまだありません",
                    systemImage: "stethoscope",
                    description: Text("会話の開始・終了やクラッシュがここに記録されます"))
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Text(displayText)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                }
                // 直近＝末尾が知りたいので下端から見せる。
                // 横は左端に寄せる（バックトレースの長い行に引きずられて時刻が隠れないように）
                .defaultScrollAnchor(.bottomLeading)
            }
        }
        .onAppear(perform: reload)
        .confirmationDialog(
            "診断ログを消しますか？", isPresented: $isConfirmingClear, titleVisibility: .visible
        ) {
            Button("クリア", role: .destructive) {
                DiagnosticsLog.clear()
                reload()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("会話履歴・記憶は消えません。次に落ちたときの手がかりが無くなるだけです。")
        }
    }

    /// 末尾 displayLineLimit 行だけ描画する（省略したら先頭にその旨を出す）。
    private var displayText: String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > Self.displayLineLimit else { return text }
        let tail = lines.suffix(Self.displayLineLimit).joined(separator: "\n")
        return "--- 古い \(lines.count - Self.displayLineLimit) 行は表示を省略（コピーには含まれます） ---\n"
            + tail
    }

    private func reload() {
        text = DiagnosticsLog.text()
        didCopy = false
    }
}
