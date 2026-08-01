import Foundation

/// AI 発話音声のローカルキャッシュの置き場（docs/plans/utterance-replay.md）。
/// `Caches/UtteranceAudio/<sessionID>/<utteranceID>.wav` に WAV（PCM16 / 24kHz / mono）で保存し、
/// 再読み上げのファイル優先再生と「直前の 1 セッションだけ残す」掃除を担う。
/// Caches 配下なので OS の容量逼迫時に消えることは許容する（消えたら再生成にフォールバック）。
struct UtteranceAudioCache: Sendable {
    /// 書き込み途中（未完）マーカーの拡張子。再生対象にせず、起動時掃除で消す
    static let partialPathExtension = "part"
    static let audioPathExtension = "wav"

    /// キャッシュのルート（既定: Caches/UtteranceAudio）。テストでは一時ディレクトリを注入する
    let rootDirectory: URL

    static let `default` = UtteranceAudioCache(
        rootDirectory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UtteranceAudio", isDirectory: true))

    func sessionDirectory(for sessionID: UUID) -> URL {
        rootDirectory.appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    /// 保存済みの完結ファイルを探す（どのセッションのディレクトリでもよい）。
    /// `.part`（未完）は無いものとして扱う。
    func audioFileURL(utteranceID: UUID) -> URL? {
        let fileManager = FileManager.default
        let directories = (try? fileManager.contentsOfDirectory(
            at: rootDirectory, includingPropertiesForKeys: nil)) ?? []
        for directory in directories {
            let url = directory.appendingPathComponent(
                utteranceID.uuidString + "." + Self.audioPathExtension)
            if fileManager.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// 保存済みファイルの PCM ペイロード（保存形式 = 再生形式なので変換不要）。
    /// 無い / 壊れているときは nil（呼び出し側が再生成にフォールバックする）。
    func pcmPayload(utteranceID: UUID) -> Data? {
        guard let url = audioFileURL(utteranceID: utteranceID),
              let data = try? Data(contentsOf: url) else { return nil }
        return Self.wavPCMPayload(data)
    }

    /// 掃除の対象選別（純関数）。残す sessionID **以外**のディレクトリ名を列挙する。
    static func directoryNamesToDelete(existing: [String], keeping sessionID: UUID?) -> [String] {
        let keep = sessionID?.uuidString
        return existing.filter { $0 != keep }
    }

    /// トリガ 1（新セッション開始時）: これから使う sessionID 以外のディレクトリを全削除する。
    /// 不変条件「完結ファイルが存在するのは最新 1 セッション分だけ」を保つ。
    func purge(keepingSessionID sessionID: UUID?) {
        let fileManager = FileManager.default
        let directories = (try? fileManager.contentsOfDirectory(
            at: rootDirectory, includingPropertiesForKeys: nil)) ?? []
        let doomed = Self.directoryNamesToDelete(
            existing: directories.map(\.lastPathComponent), keeping: sessionID)
        for name in doomed {
            try? fileManager.removeItem(at: rootDirectory.appendingPathComponent(name))
        }
    }

    /// トリガ 2（アプリ起動時）: 最新セッション以外のディレクトリと、全ディレクトリ内の
    /// `.part` を削除する。クラッシュ・強制終了でトリガ 1 を通らなかったぶんの取りこぼし対策。
    func cleanUpAtLaunch(keepingSessionID sessionID: UUID?) {
        purge(keepingSessionID: sessionID)
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: rootDirectory, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in enumerator
        where url.pathExtension == Self.partialPathExtension {
            try? fileManager.removeItem(at: url)
        }
    }

    // MARK: - WAV（PCM16 / 24kHz / mono）

    static let sampleRate = 24_000
    static let headerSize = 44

    /// dataSize バイトの PCM ペイロードを持つ WAV ヘッダ（44 バイト固定形）。
    static func wavHeader(dataSize: Int) -> Data {
        var header = Data(capacity: headerSize)
        func append(_ string: String) { header.append(contentsOf: string.utf8) }
        func append32(_ value: Int) {
            withUnsafeBytes(of: UInt32(value).littleEndian) { header.append(contentsOf: $0) }
        }
        func append16(_ value: Int) {
            withUnsafeBytes(of: UInt16(value).littleEndian) { header.append(contentsOf: $0) }
        }
        append("RIFF")
        append32(36 + dataSize)
        append("WAVE")
        append("fmt ")
        append32(16)
        append16(1)                    // PCM
        append16(1)                    // mono
        append32(sampleRate)
        append32(sampleRate * 2)       // byte rate
        append16(2)                    // block align
        append16(16)                   // bits per sample
        append("data")
        append32(dataSize)
        return header
    }

    /// 自前で書いた 44 バイト固定形ヘッダの WAV から PCM ペイロードを取り出す。
    /// 形が合わないときは nil（壊れたファイルを鳴らさない）。
    static func wavPCMPayload(_ data: Data) -> Data? {
        guard data.count > headerSize,
              data.prefix(4).elementsEqual("RIFF".utf8),
              data.subdata(in: 8..<12).elementsEqual("WAVE".utf8),
              data.subdata(in: 36..<40).elementsEqual("data".utf8) else { return nil }
        let declaredSize = data.subdata(in: 40..<44).withUnsafeBytes {
            Int(UInt32(littleEndian: $0.load(as: UInt32.self)))
        }
        let payload = data.suffix(from: headerSize)
        guard declaredSize == payload.count else { return nil }
        return Data(payload)
    }
}

/// セッション中に TTS の音声チャンクを発話（吹き出し）単位の WAV へ追記保存する
/// （docs/plans/utterance-replay.md）。CloudSentenceSpeaker の取得ループから注入されて呼ばれる。
///
/// - 書き込み中は `<utteranceID>.part`、その発話の全文の取得が完了した時点で `.wav` へ rename
///   （完了の合図 = 次の発話の先頭チャンク到着 / endStream 後のキュー読み切り）
/// - stopNow / shutdown（中断・セッション停止）では書きかけの `.part` をそのまま残す
///   （未完マーカー。再生対象にせず、起動時掃除で消える）
/// - 文単位の取得失敗があった発話は音声が欠けるため保存しない（.part のまま残す /
///   ファイル未作成なら以後のチャンクも捨てる）
///
/// 書き込みは直列キューに逃がす（取得ループは MainActor 上で回るため）。
/// 可変状態はすべて queue 上でしか触らないので @unchecked Sendable は安全。
final class UtteranceAudioRecorder: @unchecked Sendable {
    private let directory: URL
    private let queue = DispatchQueue(label: "utterance-audio-recorder", qos: .utility)
    private var currentID: UUID?
    private var currentHandle: FileHandle?
    private var currentDataBytes = 0
    /// 取得失敗した発話。以後のチャンクは捨て、完結（rename）もしない
    private var failedID: UUID?

    init(directory: URL) {
        self.directory = directory
    }

    /// 1 チャンク追記する。発話が切り替わったら前の発話を完結（.part → .wav）してから開く。
    func append(utteranceID: UUID, pcm: Data) {
        queue.async { [self] in
            if utteranceID == failedID { return }
            if currentID != utteranceID {
                finalizeLocked()
                openLocked(utteranceID: utteranceID)
            }
            currentHandle?.write(pcm)
            currentDataBytes += pcm.count
        }
    }

    /// 発話の取得失敗（文単位のスキップ）。音声が欠けた発話は保存しない。
    func markFailed(utteranceID: UUID) {
        queue.async { [self] in
            failedID = utteranceID
            guard currentID == utteranceID else { return }
            // 書きかけは .part のまま残す（未完マーカー）
            try? currentHandle?.close()
            currentHandle = nil
            currentID = nil
            currentDataBytes = 0
        }
    }

    /// ターンの全発話の取得が完了した（endStream 後のキュー読み切り）。最後の発話を完結する。
    func finishCurrent() {
        queue.async { [self] in
            finalizeLocked()
        }
    }

    /// stopNow / shutdown（中断・セッション停止）。書きかけの `.part` をそのまま残す。
    func abandonCurrent() {
        queue.async { [self] in
            try? currentHandle?.close()
            currentHandle = nil
            currentID = nil
            currentDataBytes = 0
        }
    }

    /// テスト用: キューに積まれた書き込みが終わるまで待つ。
    func waitUntilIdle() {
        queue.sync {}
    }

    // MARK: - queue 上でのみ呼ぶ

    private func partURL(utteranceID: UUID) -> URL {
        directory.appendingPathComponent(
            utteranceID.uuidString + "." + UtteranceAudioCache.partialPathExtension)
    }

    private func openLocked(utteranceID: UUID) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = partURL(utteranceID: utteranceID)
        // サイズはまだ分からないのでプレースホルダ（0）のヘッダを先に書き、完結時に埋める
        guard fileManager.createFile(
            atPath: url.path, contents: UtteranceAudioCache.wavHeader(dataSize: 0)),
            let handle = try? FileHandle(forWritingTo: url)
        else {
            DiagnosticsLog.record("!! replay: 音声キャッシュのファイル作成に失敗 \(url.lastPathComponent)")
            failedID = utteranceID
            return
        }
        handle.seekToEndOfFile()
        currentHandle = handle
        currentID = utteranceID
        currentDataBytes = 0
    }

    /// ヘッダのサイズを埋めて .part → .wav へ rename する（発話の完結）。
    private func finalizeLocked() {
        defer {
            currentHandle = nil
            currentID = nil
            currentDataBytes = 0
        }
        guard let handle = currentHandle, let id = currentID else { return }
        // 中身が空のファイルは残さない（TTS が 1 チャンクも返さなかった発話）
        guard currentDataBytes > 0 else {
            try? handle.close()
            try? FileManager.default.removeItem(at: partURL(utteranceID: id))
            return
        }
        handle.seek(toFileOffset: 0)
        handle.write(UtteranceAudioCache.wavHeader(dataSize: currentDataBytes))
        try? handle.close()
        let partURL = partURL(utteranceID: id)
        let audioURL = partURL.deletingPathExtension()
            .appendingPathExtension(UtteranceAudioCache.audioPathExtension)
        try? FileManager.default.moveItem(at: partURL, to: audioURL)
    }
}
