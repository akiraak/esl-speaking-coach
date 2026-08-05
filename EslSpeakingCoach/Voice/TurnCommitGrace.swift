import Foundation

/// 発話終端から会話ターンを Claude へ投げるまでの**送信猶予**
/// （docs/plans/always-on-voice-input.md Phase 1）。
///
/// 無音 0.8 秒でセグメントを切ったあと即座に送ると、言い淀んだだけで
/// `"I went to the... "` のような中途半端なテキストがターンになってしまう。
/// 終端の時点で猶予を張り、その間に続きを話せば同じターンへ継ぎ足す
/// （`silenceDuration` を伸ばす案 B1 と違い、**認識は先に走らせて送信だけ待つ**ので
/// STT の確定待ちと並行し、純増ぶんは猶予から確定待ちを引いた残りで済む）。
///
/// 長さは確定テキストの末尾で出し分ける。**画面に出すのは標準値だけ**で、
/// 長短は標準からの固定比（`continuingScale` / `completedScale`）で導く。
/// `AudioTapRouter` 側の判定と同じく副作用を持たない値型にして、境界値をテストで固定する。
struct TurnCommitGrace: Sendable, Equatable {
    /// 猶予の長さがどう決まったか。
    enum Kind: Sendable, Equatable {
        /// 明らかに続きがある（接続詞・前置詞・冠詞・be 動詞・助動詞・フィラーで終わった）
        case continuing
        /// 文として完結している（`.` `?` `!` で終わった）。現行に近い応答速度を保つ
        case completed
        /// どちらとも言えない
        case standard

        var label: String {
            switch self {
            case .continuing: return "続きそう"
            case .completed: return "完結"
            case .standard: return "標準"
            }
        }
    }

    struct Decision: Sendable, Equatable {
        var kind: Kind
        /// 発話終端からこの秒数が経つまで送信を待つ
        var duration: TimeInterval
        /// 判定の根拠になった末尾（会話ログ用。標準判定なら空）
        var trigger: String

        /// 会話ログの 1 行（`1.60 秒（続きそう: "the"）`）。
        var logDescription: String {
            let seconds = String(format: "%.2f 秒", duration)
            guard !trigger.isEmpty else { return "\(seconds)（\(kind.label)）" }
            return "\(seconds)（\(kind.label): \"\(trigger)\"）"
        }
    }

    /// 標準の猶予（秒）。0 にすると猶予なし（＝従来どおり確定した瞬間に送る）。
    var standard: TimeInterval = 1.0

    /// 続きがありそうな終わり方の倍率（標準 1.0 秒に対して 1.6 秒）
    static let continuingScale: Double = 1.6
    /// 完結文の倍率（標準 1.0 秒に対して 0.4 秒）
    static let completedScale: Double = 0.4

    /// 確定テキストから猶予を決める。空文字は判断材料が無いので標準にする
    /// （呼び出し側では空セグメントに猶予を挟まないので実際には通らない）。
    func decide(for text: String) -> Decision {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else {
            return Decision(kind: .standard, duration: standard, trigger: "")
        }

        // 記号での判定を先に見る（STT が句読点を出す場合はこちらが効く）。
        // 3 点リーダは「言い淀んで切れた」印なので完結扱いにしない
        if trimmed.hasSuffix("...") || trimmed.hasSuffix("…") {
            return decision(kind: .continuing, trigger: "…")
        }
        if Self.terminators.contains(last) {
            return decision(kind: .completed, trigger: String(last))
        }
        if Self.continuingMarks.contains(last) {
            return decision(kind: .continuing, trigger: String(last))
        }

        // live の STT は句読点を出さないことがあるので、末尾の語だけでも判定できるようにする
        let word = Self.lastWord(of: trimmed)
        if !word.isEmpty, Self.continuingWords.contains(word) {
            return decision(kind: .continuing, trigger: word)
        }
        return decision(kind: .standard, trigger: "")
    }

    private func decision(kind: Kind, trigger: String) -> Decision {
        let duration: TimeInterval
        switch kind {
        case .continuing: duration = standard * Self.continuingScale
        case .completed: duration = standard * Self.completedScale
        case .standard: duration = standard
        }
        return Decision(kind: kind, duration: duration, trigger: trigger)
    }

    /// 末尾の語を小文字で取り出す（前後の記号は落とし、`don't` のアポストロフィは残す）。
    static func lastWord(of text: String) -> String {
        let separators = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
            .subtracting(CharacterSet(charactersIn: "'’"))
        let words = text.components(separatedBy: separators).filter { !$0.isEmpty }
        return words.last?.lowercased() ?? ""
    }

    private static let terminators: Set<Character> = [".", "?", "!", "。", "？", "！"]
    /// 読点・ダッシュで終わっていれば続きがある
    private static let continuingMarks: Set<Character> = [",", "-", "–", "—", "、"]

    /// これで終わったら「まだ続く」とみなす語。
    /// **文末にも普通に立つ語（`you` `it` `that` `there` `some` `well` `no` `yes` など）は入れない**
    /// — 入れると完結した発話まで 1.6 秒待たされ、体感レイテンシがまるごと悪化する。
    private static let continuingWords: Set<String> = [
        // 接続詞
        "and", "but", "so", "or", "because", "although", "though", "while", "when",
        "whenever", "if", "unless", "since", "until", "than", "whether", "as",
        // 前置詞
        "to", "of", "in", "on", "at", "for", "with", "from", "by", "about", "into",
        "onto", "over", "under", "after", "before", "between", "through", "during",
        // 冠詞・限定詞
        "a", "an", "the", "my", "your", "our", "their", "its",
        // 代名詞（主語の位置で切れた形。`you` `it` は文末にも立つので除く）
        "i", "we", "they", "he", "she",
        // be 動詞・助動詞
        "is", "are", "am", "was", "were", "be", "been", "being",
        "do", "does", "did", "have", "has", "had",
        "can", "could", "will", "would", "shall", "should", "may", "might", "must",
        "i'm", "i've", "i'll", "it's", "that's", "there's", "don't", "doesn't", "didn't",
        // フィラー（言い淀みそのもの）
        "um", "umm", "uh", "uhh", "er", "err", "ah", "eh", "hmm", "mmm", "like", "kinda",
        "very", "just",
    ]
}
