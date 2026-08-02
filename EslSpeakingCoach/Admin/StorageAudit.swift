import Foundation

/// アプリが端末に書いているファイルの棚卸し（docs/plans/archive/chat-storage-audit.md Phase 1）。
/// 管理画面「容量」タブに出す各項目のサイズを実測する。書き込み箇所はコード上の全数調査で
/// 確定済みなので、ここに列挙した 4 箇所 + UserDefaults / Keychain（定数個）で全部。
enum StorageAudit {
    /// 表示 1 項目分。
    struct Item: Identifiable, Sendable {
        let title: String
        let bytes: Int64
        let fileCount: Int
        var id: String { title }
    }

    struct Report: Sendable {
        /// default.store 本体（セッション・発話・ログ・usage・記憶。無期限に蓄積する唯一の場所）
        let database: Item
        /// -wal / -shm。書き込み中の作業領域で、チェックポイントで本体へ畳まれる。
        /// ファイルは縮まないが高水位で頭打ちになるので、蓄積量の指標には使わない
        let databaseJournal: Item
        /// Diagnostics/app.log（256KB で切り詰めるので頭打ち）
        let diagnostics: Item
        /// Caches/UtteranceAudio（常に最新 1 セッション分。OS の掃除も許容）
        let audioCache: Item
        /// tmp のセッション書き出し残骸（起動時と共有後に掃除する。通常 0 のはず）
        let exportLeftovers: Item

        var items: [Item] {
            [database, databaseJournal, diagnostics, audioCache, exportLeftovers]
        }
        var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    }

    // MARK: - 選別（純関数）

    /// SwiftData ストア本体。
    static func isSwiftDataStoreFile(_ name: String) -> Bool {
        name == "default.store"
    }

    /// SwiftData ストアのジャーナル（-wal / -shm）。
    static func isSwiftDataJournalFile(_ name: String) -> Bool {
        name.hasPrefix("default.store-")
    }

    // MARK: - 実測

    /// 既定の置き場（実機・シミュレータ）で実測する。ファイル I/O のみなのでバックグラウンド可。
    static func measure() -> Report {
        let fileManager = FileManager.default
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL.temporaryDirectory
        let caches = fileManager.urls(
            for: .cachesDirectory, in: .userDomainMask).first ?? URL.temporaryDirectory
        return measure(
            applicationSupport: applicationSupport,
            audioCacheRoot: caches.appendingPathComponent("UtteranceAudio", isDirectory: true),
            temporary: fileManager.temporaryDirectory)
    }

    /// 置き場を注入して実測する（テスト用）。
    static func measure(applicationSupport: URL, audioCacheRoot: URL, temporary: URL) -> Report {
        let database = item(
            title: "データベース（SwiftData）",
            measured: topLevelFilesSize(in: applicationSupport, matching: isSwiftDataStoreFile))
        let databaseJournal = item(
            title: "└ ジャーナル",
            measured: topLevelFilesSize(in: applicationSupport, matching: isSwiftDataJournalFile))
        let diagnostics = item(
            title: "診断ログ",
            measured: directorySize(
                at: applicationSupport.appendingPathComponent("Diagnostics", isDirectory: true)))
        let audioCache = item(
            title: "音声キャッシュ", measured: directorySize(at: audioCacheRoot))
        let exportLeftovers = item(
            title: "エクスポート残骸",
            measured: topLevelFilesSize(in: temporary, matching: SessionExporter.isExportFileName))
        return Report(
            database: database, databaseJournal: databaseJournal, diagnostics: diagnostics,
            audioCache: audioCache, exportLeftovers: exportLeftovers)
    }

    private static func item(title: String, measured: (bytes: Int64, fileCount: Int)) -> Item {
        Item(title: title, bytes: measured.bytes, fileCount: measured.fileCount)
    }

    /// ディレクトリ直下のファイルのうち、名前が predicate に合うものの合計サイズ。
    static func topLevelFilesSize(
        in directory: URL, matching predicate: (String) -> Bool
    ) -> (bytes: Int64, fileCount: Int) {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])) ?? []
        var bytes: Int64 = 0
        var count = 0
        for url in urls where predicate(url.lastPathComponent) {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            bytes += Int64(values.fileSize ?? 0)
            count += 1
        }
        return (bytes, count)
    }

    /// ディレクトリ以下（再帰）の全ファイルの合計サイズ。存在しなければ 0。
    static func directorySize(at directory: URL) -> (bytes: Int64, fileCount: Int) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: keys) else { return (0, 0) }
        var bytes: Int64 = 0
        var count = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            bytes += Int64(values.fileSize ?? 0)
            count += 1
        }
        return (bytes, count)
    }

    // MARK: - 表示

    /// バイト数の表示（1024 区切り。ロケール非依存でテストできるよう自前で組む）。
    static func formattedBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: mb < 10 ? "%.2f MB" : "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024)
    }
}
