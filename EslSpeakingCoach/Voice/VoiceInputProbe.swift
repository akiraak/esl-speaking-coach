import Foundation

/// いつでも話せる音声入力（docs/plans/always-on-voice-input.md）の **Phase 2: 実測**用プローブ。
/// Phase 3 以降の設計判断に必要な 3 つの数字を実機で取るためだけの診断で、
/// 音声パスの挙動は一切変えない（読むだけ・記録するだけ）。
///
/// 1. partial delta がセグメントの**途中に**届くか / どれくらい遅れるか
///    → 届かないなら回収ウィンドウ③（読み上げ直後の言い直し）の確定条件
///      「partial が 2 語以上」を満たせない
/// 2. 確定テキストに**句読点**が入るか → 送信猶予（`TurnCommitGrace`）の出し分けに使えるか
/// 3. 読み上げ中のマイク RMS（VP 通過後の**エコー残留**）
///    → AI ターン中に開けるゲートの絶対値しきい値をいくつにするか
///
/// 出力先は診断ログ（管理画面「診断ログ」）。会話ログには出さない。

// MARK: - STT セグメントの到達タイミング（実測 1・2）

/// STT セグメント 1 件の時間軸を記録する。発話開始（VAD）を起点に、partial delta の
/// 到達・commit（発話終端）・確定テキストの時刻を並べ、1 行に畳んで診断ログへ残す。
///
/// 時刻は呼び出し側から渡す（純粋な値型に保ち、境界値をテストで固定するため）。
struct SegmentTranscriptProbe: Sendable, Equatable {
    /// partial delta の到達 1 件ぶん。
    struct DeltaSample: Sendable, Equatable {
        /// 発話開始からの経過秒
        var offset: TimeInterval
        /// その時点での累積 partial の語数（回収・割り込みの確定条件が「2 語以上」なので語数で見る）
        var wordCount: Int
        /// commit（発話終端）より前に届いたか。**ここが実測 1 の本体** —
        /// すべて commit 後なら、読み上げ中の割り込みを partial で確定する案は成立しない
        var isBeforeCommit: Bool
    }

    /// 発話開始（VAD が speechStarted を出した時刻）
    let startedAt: Date
    private(set) var deltas: [DeltaSample] = []
    private(set) var committedAt: Date?

    init(startedAt: Date) {
        self.startedAt = startedAt
    }

    mutating func recordPartial(_ text: String, at instant: Date) {
        deltas.append(DeltaSample(
            offset: instant.timeIntervalSince(startedAt),
            wordCount: Self.wordCount(of: text),
            isBeforeCommit: committedAt == nil))
    }

    /// 発話終端（live なら input_audio_buffer.commit を送った時点）。
    mutating func recordCommit(at instant: Date) {
        guard committedAt == nil else { return }
        committedAt = instant
    }

    /// 確定テキスト（認識失敗なら nil）を受けて診断ログの 1 行に畳む。
    func summaryLine(final transcript: String?, at instant: Date) -> String {
        var parts: [String] = []
        let spokenUntil = committedAt ?? instant
        parts.append(String(format: "発話 %.2fs", spokenUntil.timeIntervalSince(startedAt)))
        parts.append(deltaSummary())
        if let committedAt {
            parts.append(String(format: "commit→final %.2fs", instant.timeIntervalSince(committedAt)))
        } else {
            parts.append("commit なし")
        }
        if let transcript {
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            parts.append("final \(Self.wordCount(of: trimmed)) 語 \(Self.punctuationNote(for: trimmed))")
            parts.append("「\(DiagnosticsSnippet.make(trimmed, limit: 160))」")
        } else {
            parts.append("final なし")
        }
        return "probe stt: " + parts.joined(separator: " / ")
    }

    private func deltaSummary() -> String {
        guard let first = deltas.first else { return "delta なし" }
        let beforeCommit = deltas.filter(\.isBeforeCommit)
        var detail = String(format: "delta %d 件（初回 +%.2fs", deltas.count, first.offset)
        if let twoWords = deltas.first(where: { $0.wordCount >= 2 }) {
            detail += String(format: " / 2 語 +%.2fs", twoWords.offset)
        } else {
            detail += " / 2 語 未到達"
        }
        detail += " / commit 前 \(beforeCommit.count) 件"
        detail += "（\(beforeCommit.last?.wordCount ?? 0) 語）"
        detail += "・後 \(deltas.count - beforeCommit.count) 件）"
        return detail
    }

    /// 空白区切りの語数（partial / final の進み具合を語数で比べるためだけの粗い数え方）。
    static func wordCount(of text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// 句読点の有無（実測 2）。`TurnCommitGrace` が記号で出し分けられるかの判断材料。
    static func punctuationNote(for text: String) -> String {
        guard let last = text.last else { return "末尾なし・読点なし" }
        let head = Self.terminators.contains(last) ? "末尾\"\(last)\"" : "末尾記号なし"
        let hasComma = text.contains(where: { Self.commas.contains($0) })
        return head + (hasComma ? "・読点あり" : "・読点なし")
    }

    private static let terminators: Set<Character> = [".", "?", "!"]
    private static let commas: Set<Character> = [",", ";", ":"]
}

// MARK: - 読み上げ中のエコー残留（実測 3）

/// AI の読み上げ中にマイクへ届いた RMS を集計する（Voice Processing 通過後の残留エコー）。
/// AI ターン中もゲートを開ける Phase 3 で、`ClientSpeechEndpointer` の絶対値しきい値
/// （`minimumPeak`）と発話開始の継続時間（`minimumSpeechDuration`）をいくつにすれば
/// 自分の声で自滅しないかを決めるための実測。
///
/// 平均・最大だけでは足りない。エンドポインタは「しきい値超えが**連続**して
/// `minimumSpeechDuration` 続く」ことで発火するので、**候補しきい値ごとの連続超過の最長時間**が
/// そのまま「その設定なら誤発火するか」の答えになる。
struct PlaybackEchoProbe: Sendable, Equatable {
    /// 候補しきい値。**listening の `minimumPeak` の倍数**で刻む（絶対値で固定すると、
    /// 管理画面でしきい値を動かした瞬間に判定点を跨げなくなる）。
    /// AI ターン中に何倍へ持ち上げれば誤発火しないか、がそのまま読める
    static let defaultScales: [Float] = [1.0, 1.5, 2.0, 3.0]

    static func thresholds(base: Float, scales: [Float] = defaultScales) -> [Float] {
        scales.map { base * $0 }
    }

    struct ThresholdStat: Sendable, Equatable {
        let threshold: Float
        /// しきい値を超えていた合計時間
        private(set) var totalAbove: TimeInterval = 0
        /// しきい値を**連続で**超えていた最長時間（= 発話開始とみなされうる長さ）
        private(set) var longestRun: TimeInterval = 0
        private var currentRun: TimeInterval = 0

        init(threshold: Float) {
            self.threshold = threshold
        }

        fileprivate mutating func record(level: Float, duration: TimeInterval) {
            guard level >= threshold else {
                currentRun = 0
                return
            }
            totalAbove += duration
            currentRun += duration
            longestRun = max(longestRun, currentRun)
        }
    }

    private(set) var duration: TimeInterval = 0
    private(set) var bufferCount = 0
    private(set) var peak: Float = 0
    private(set) var stats: [ThresholdStat]
    private var levelSum: Double = 0

    init(thresholds: [Float]) {
        stats = thresholds.map(ThresholdStat.init(threshold:))
    }

    var mean: Float {
        guard bufferCount > 0 else { return 0 }
        return Float(levelSum / Double(bufferCount))
    }

    /// タップバッファ 1 つぶんの RMS を取り込む（オーディオスレッドからロック下で呼ばれる）。
    mutating func record(level: Float, duration: TimeInterval) {
        self.duration += duration
        bufferCount += 1
        peak = max(peak, level)
        levelSum += Double(level)
        for index in stats.indices {
            stats[index].record(level: level, duration: duration)
        }
    }

    /// 診断ログの 1 行。`context` には暗騒音・VP の有無・出力経路を入れる
    /// （エコーの乗り方は経路と VP で大きく変わるため、数字だけ見ても判断できない）。
    func summaryLine(context: String) -> String {
        let head = String(
            format: "読み上げ %.2fs / rms 平均 %.4f 最大 %.4f / %d buf",
            duration, mean, peak, bufferCount)
        let detail = stats
            .map { String(format: ">%.4f %.2fs(最長 %.2fs)", $0.threshold, $0.totalAbove, $0.longestRun) }
            .joined(separator: " / ")
        let tail = context.isEmpty ? "" : " / \(context)"
        return "probe echo: \(head) / \(detail)\(tail)"
    }
}
