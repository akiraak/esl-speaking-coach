import Darwin
import Foundation

/// 端末で落ちたときに「直前に何をしていたか」を後から読むための追記型ログ
/// （docs/plans/end-session-crash.md Phase 0）。
///
/// SwiftData の会話ログ（`ChatHistoryStore.appendLog`）と違い、
/// - セッション外（終了処理・アプリ起動/終了）も記録できる
/// - クラッシュハンドラから **write(2) だけ**で追記できる（malloc 不要 = シグナル内でも書ける）
/// - 次回起動後も残る（起動ごとにバナー行を挟み、上限を超えたら古い方から捨てる）
///
/// 追記は O_APPEND の write(2) なのでバッファに溜まらず、プロセスが abort しても書いた分は残る。
final class DiagnosticsLogFile: @unchecked Sendable {
    /// これを超えたら切り詰める（切り詰め後は keepBytes を残す）
    static let defaultMaxBytes = 256 * 1024
    static let defaultKeepBytes = 128 * 1024

    private let url: URL
    private let lock = NSLock()
    private var descriptor: Int32 = -1

    init(url: URL) {
        self.url = url
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }

    /// ログファイルを開く（無ければ作る）。上限超過分は先に切り詰める。
    /// 戻り値はクラッシュハンドラへ渡すファイルディスクリプタ（失敗時は -1）。
    @discardableResult
    func open(maxBytes: Int = defaultMaxBytes, keepBytes: Int = defaultKeepBytes) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor < 0 else { return descriptor }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        truncateIfNeeded(maxBytes: maxBytes, keepBytes: keepBytes)
        descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        }
        return descriptor
    }

    /// 1 行追記する（時刻を前置し、末尾に改行を付ける）。
    func append(_ message: String, at date: Date = Date()) {
        let line = Self.timestamp(date) + " " + message + "\n"
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { return }
        var bytes = Array(line.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return write(descriptor, base + offset, buffer.count - offset)
            }
            guard written > 0 else { return }
            offset += written
        }
    }

    /// ファイル全体（管理画面表示・コピー用）。
    func text() -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// 中身を消す（管理画面の「クリア」）。ファイルは開いたまま使い続ける。
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? Data().write(to: url)
        if descriptor >= 0 {
            ftruncate(descriptor, 0)
            lseek(descriptor, 0, SEEK_END)
        }
    }

    /// 上限超過時に末尾 keepBytes だけ残す（行の途中で切らないよう最初の改行まで捨てる）。
    private func truncateIfNeeded(maxBytes: Int, keepBytes: Int) {
        guard let data = try? Data(contentsOf: url), data.count > maxBytes else { return }
        var tail = data.suffix(keepBytes)
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) {
            tail = tail[tail.index(after: newline)...]
        }
        let notice = Data("--- 古いログはサイズ上限で切り詰めました ---\n".utf8)
        try? (notice + tail).write(to: url)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private static func timestamp(_ date: Date) -> String {
        formatter.string(from: date)
    }
}

/// アプリ全体で共有する診断ログ。起動時に `start()` を呼ぶ。
enum DiagnosticsLog {
    static let shared = DiagnosticsLogFile(url: defaultURL)

    /// Application Support 配下（Caches と違い OS に消されない）。
    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL.temporaryDirectory
        return base.appending(path: "Diagnostics/app.log")
    }

    /// 起動直後に呼ぶ。ログを開き、起動バナーを書き、クラッシュハンドラを仕掛ける。
    static func start() {
        let descriptor = shared.open()
        shared.append(launchBanner())
        DiagnosticsCrashReporter.install(descriptor: descriptor)
    }

    static func record(_ message: String) {
        shared.append(message)
    }

    static func text() -> String {
        shared.text()
    }

    static func clear() {
        shared.clear()
        shared.append("--- ログをクリアしました ---")
    }

    /// 起動ごとの区切り行。ここより上が前回起動ぶん。
    private static func launchBanner() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { buffer in
            String(cString: buffer.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "=== 起動 app \(version) (\(build)) / iOS \(os.majorVersion).\(os.minorVersion)"
            + ".\(os.patchVersion) / \(machine) ==="
    }
}

// MARK: - スニペット整形

/// API の生の応答など、長さも中身も信用できない文字列を診断ログへ埋め込むための整形
/// （docs/plans/feedback-truncated.md Phase 1）。純関数なのでテストから直接叩ける。
enum DiagnosticsSnippet {
    /// 改行系をエスケープし、`limit` 文字を超えるぶんは中略する。
    /// 中略は頭 2/3・尻 1/3 で残す（JSON なら先頭の壊れ方と閉じ括弧の有無が両方見える）。
    static func make(_ text: String, limit: Int) -> String {
        let escaped = escapeLineBreaks(text)
        guard escaped.count > limit, limit >= 3 else { return escaped }
        let headCount = limit * 2 / 3
        let head = escaped.prefix(headCount)
        let tail = escaped.suffix(limit - headCount)
        return "\(head)…〈中略 全 \(escaped.count) 字〉…\(tail)"
    }

    /// 改行として扱われる文字を可視化する。ログを 1 行に保つためだけでなく、
    /// **これらが生の応答に混ざっていること自体が容疑**（`bytes.lines` は LF/CR 以外の
    /// VT・FF・NEL・LS・PS でも行を切る）なので、見える形で残す。
    static func escapeLineBreaks(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\u{0B}": output += "\\u000b"
            case "\u{0C}": output += "\\u000c"
            case "\u{85}": output += "\\u0085"
            case "\u{2028}": output += "\\u2028"
            case "\u{2029}": output += "\\u2029"
            default: output.unicodeScalars.append(scalar)
            }
        }
        return output
    }
}

// MARK: - クラッシュハンドラ

/// 未捕捉の Objective-C 例外（AVFoundation のアサート等）と致命シグナルを診断ログへ残す。
/// シグナルハンドラ内では malloc できないため、事前に確保したバッファと write(2) だけを使う。
enum DiagnosticsCrashReporter {
    private static let backtraceCapacity = 64

    static func install(descriptor: Int32) {
        guard descriptor >= 0 else { return }
        crashLogDescriptor = descriptor
        crashBacktraceBuffer = UnsafeMutablePointer<UnsafeMutableRawPointer?>
            .allocate(capacity: backtraceCapacity)

        NSSetUncaughtExceptionHandler { exception in
            // ここはシグナルコンテキストではないので通常の Swift を使ってよい
            let name = exception.name.rawValue
            let reason = exception.reason ?? "-"
            let stack = exception.callStackSymbols.prefix(24).joined(separator: "\n")
            DiagnosticsLog.shared.append("!!! 未捕捉の例外 \(name): \(reason)\n\(stack)")
        }

        for number in [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP] {
            signal(number, handleFatalSignal)
        }
    }
}

/// シグナルハンドラから触るためグローバルに置く（ハンドラは C 関数なのでキャプチャできない）。
private nonisolated(unsafe) var crashLogDescriptor: Int32 = -1
private nonisolated(unsafe) var crashBacktraceBuffer: UnsafeMutablePointer<UnsafeMutableRawPointer?>?

/// 致命シグナルの記録。write(2) と backtrace_symbols_fd だけで完結させる（malloc しない）。
private func handleFatalSignal(_ number: Int32) {
    let name: StaticString
    switch number {
    case SIGABRT: name = "\n!!! シグナル SIGABRT（例外・アサート）\n"
    case SIGILL: name = "\n!!! シグナル SIGILL\n"
    case SIGSEGV: name = "\n!!! シグナル SIGSEGV\n"
    case SIGFPE: name = "\n!!! シグナル SIGFPE\n"
    case SIGBUS: name = "\n!!! シグナル SIGBUS\n"
    case SIGTRAP: name = "\n!!! シグナル SIGTRAP（Swift の実行時エラー）\n"
    default: name = "\n!!! シグナル（不明）\n"
    }
    if crashLogDescriptor >= 0 {
        _ = write(crashLogDescriptor, name.utf8Start, name.utf8CodeUnitCount)
        if let buffer = crashBacktraceBuffer {
            let count = backtrace(buffer, 64)
            backtrace_symbols_fd(buffer, count, crashLogDescriptor)
        }
    }
    // 既定の処理へ戻して OS のクラッシュレポート（.ips）も従来どおり残す
    signal(number, SIG_DFL)
    raise(number)
}
