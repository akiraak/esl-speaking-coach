import Foundation

/// AI 自身の読み上げがマイクへ回り込んで認識されたもの（エコー）かを判定する純関数
/// （docs/plans/always-on-voice-input.md Phase 5）。
///
/// 常時入力（Phase 3）で読み上げ中もマイクを開けたため、Voice Processing（AEC）を
/// すり抜けたエコーが**テキストになる**余地ができた。放っておくと
/// 「AI の声で AI が止まる」（Phase 4 の割り込みが誤確定する）か、
/// AI の発言がそのまま学習者のターンとして送られる。
///
/// 一次防衛はあくまで**しきい値**（読み上げ中は `minimumPeak` ×1.5・発話開始 0.30 秒）で、
/// 実測ではエコーは VAD すら鳴らせていない。これはその上に重ねる保険で、
/// 音量を上げた・部屋が響く等でエコーが通ってしまったときに効く。
///
/// ## 単語の重なりではなく「語順の連続一致」で見る
///
/// 英会話練習では**学習者が AI の言い回しをそのまま使うのが普通**なので、
/// 単語の集合が重なっているだけでエコー扱いすると正当な発話まで捨ててしまう
/// （AI: "the airport is far" → 学習者: "yes the airport is far from here"）。
/// エコーは AI の発話そのものなので**語順まで一致する**。そこで
/// 「連続して一致した最長の語数」で判定する。
///
/// ただし連続一致だけでは足りない。**言い回しを借りた学習者の発話**も
/// 5 語くらいは平気で一致する（"yes I like reading a book too but not every night"）。
/// これと**認識を取り違えたエコー**（"so what do you usually **to** before **bad**"）は、
/// 連続一致の長さでは区別できない。分かれるのは**残りの語**で:
/// - エコーは全体が AI の発話なので、外れた語も AI が言った語（＝ 被覆率が高い）
/// - 学習者の発話は、借りた部分の外側が自分の言葉（＝ 被覆率が低い）
///
/// そこで「連続一致の長さ」と「確定テキストのうち読み上げに含まれる語の割合（被覆率）」の
/// 両方で見る。
enum AssistantEchoFilter {
    /// 長めの発話向け: この語数以上の連続一致 かつ 被覆率が `longRunCoverage` 以上
    static let longRunLength = 4
    static let longRunCoverage = 0.7
    /// 短い発話向け: この語数以上の連続一致が、確定テキストの `shortRunRatio` 以上を占めたら
    static let shortRunLength = 3
    static let shortRunRatio = 0.75

    /// - Parameters:
    ///   - transcript: STT の確定テキスト（または途中経過）
    ///   - spokenText: **その時点までに実際に読み上げた** AI の発話テキスト。
    ///     読み上げていない先の文まで入れると、判定が甘くなるぶん誤検知が増える
    static func isEcho(transcript: String, spokenText: String) -> Bool {
        let heard = tokens(transcript)
        let spoken = tokens(spokenText)
        guard !heard.isEmpty, !spoken.isEmpty else { return false }
        let run = longestCommonRun(heard, spoken)
        if run >= longRunLength, coverage(of: heard, in: Set(spoken)) >= longRunCoverage {
            return true
        }
        guard run >= shortRunLength else { return false }
        return Double(run) / Double(heard.count) >= shortRunRatio
    }

    /// 確定テキストのうち、読み上げに出てきた語がどれだけを占めるか（語順は問わない）。
    static func coverage(of heard: [String], in spoken: Set<String>) -> Double {
        guard !heard.isEmpty else { return 0 }
        return Double(heard.filter(spoken.contains).count) / Double(heard.count)
    }

    /// 小文字化して記号を落とした語の並び（`BackchannelFilter` と同じ切り方）。
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// 2 つの語列で**連続して**一致する最長の長さ（最長共通部分文字列の語版）。
    static func longestCommonRun(_ lhs: [String], _ rhs: [String]) -> Int {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        // 直前の行だけ持てば足りる（語数は高々数十なので素直な DP でよい）
        var previous = [Int](repeating: 0, count: rhs.count + 1)
        var current = previous
        var longest = 0
        for i in 1...lhs.count {
            for j in 1...rhs.count {
                current[j] = lhs[i - 1] == rhs[j - 1] ? previous[j - 1] + 1 : 0
                longest = max(longest, current[j])
            }
            swap(&previous, &current)
        }
        return longest
    }
}
