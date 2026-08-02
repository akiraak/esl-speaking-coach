import SwiftUI

/// 管理画面「容量」タブ: 端末に書いているファイルの内訳とレコード件数
/// （docs/plans/archive/chat-storage-audit.md Phase 1）。
/// 無期限に増えるのは SwiftData ストアだけ、を実測で確かめるための画面。
struct StorageUsageView: View {
    let historyStore: ChatHistoryStore
    let usageStore: UsageStore

    @State private var report: StorageAudit.Report?
    @State private var counts = ChatHistoryStore.RecordCounts()
    @State private var usageRecordCount = 0
    @State private var isConfirmingAudioPurge = false

    var body: some View {
        List {
            Section {
                if let report {
                    ForEach(report.items) { item in
                        sizeRow(
                            title: item.title,
                            bytes: item.bytes,
                            detail: item.fileCount > 0 ? "\(item.fileCount) ファイル" : nil)
                    }
                    sizeRow(title: "合計", bytes: report.totalBytes, detail: nil)
                        .fontWeight(.semibold)
                } else {
                    HStack {
                        Text("計測中…")
                        Spacer()
                        ProgressView()
                    }
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("保存ファイル")
            } footer: {
                Text(
                    "無期限に増えるのはデータベース本体だけ。ジャーナル（-wal / -shm）は"
                    + "書き込みの作業領域で高水位まで、診断ログは 256KB で頭打ち、"
                    + "音声キャッシュは直前の 1 セッション分のみ、エクスポート残骸は起動時に掃除される。")
            }

            Section {
                countRow(title: "セッション", count: counts.sessions)
                countRow(title: "発話", count: counts.messages)
                countRow(title: "調査ログ", count: counts.logs)
                countRow(title: "API 利用記録", count: usageRecordCount)
                if let report, counts.sessions > 0 {
                    sizeRow(
                        title: "データベース ÷ セッション数",
                        bytes: report.database.bytes / Int64(counts.sessions),
                        detail: nil)
                }
            } header: {
                Text("レコード件数")
            } footer: {
                Text(
                    "「データベース ÷ セッション数」が 1 セッションあたりの増分の概算"
                    + "（実測 13KB 前後。毎日 1 セッションでも年 5MB 程度なので履歴は全部残す）。")
            }

            Section {
                Button("音声キャッシュを全削除", role: .destructive) {
                    isConfirmingAudioPurge = true
                }
                Button("再計測") { reload() }
            } footer: {
                Text("音声は再読み上げ時に TTS で再生成できるため、消しても会話履歴には影響しない。")
            }
        }
        .onAppear(perform: reload)
        .confirmationDialog(
            "音声キャッシュを全削除しますか？",
            isPresented: $isConfirmingAudioPurge, titleVisibility: .visible
        ) {
            Button("全削除", role: .destructive) { purgeAudioCache() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("会話履歴・記憶は消えません。再読み上げは TTS の再生成になります。")
        }
    }

    private func sizeRow(title: String, bytes: Int64, detail: String?) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text(StorageAudit.formattedBytes(bytes))
                .monospacedDigit()
        }
    }

    private func countRow(title: String, count: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(count) 行")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func reload() {
        counts = historyStore.recordCounts()
        usageRecordCount = usageStore.recordCount()
        Task.detached(priority: .userInitiated) {
            let report = StorageAudit.measure()
            await MainActor.run { self.report = report }
        }
    }

    private func purgeAudioCache() {
        Task.detached(priority: .userInitiated) {
            // セッション中でも全削除してよい（書き込み中ハンドルは unlink 済みファイルへ書き、
            // 完結時の rename が失敗するだけ。再生はファイル無し = TTS 再生成へフォールバック）
            UtteranceAudioCache.default.purge(keepingSessionID: nil)
            await MainActor.run { reload() }
        }
    }
}
