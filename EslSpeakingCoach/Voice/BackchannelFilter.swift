import Foundation

/// 相槌・中身のない短い返事だけの発話かを判定する純関数
/// （docs/plans/always-on-voice-input.md Phase 3.5）。
///
/// 落としたいものは 4 種類ある（④は語数、①〜③は語彙で見る）。
/// 1. **聞きながらの相槌**（「Um」「うん」）。常時入力（Phase 3）で AI の読み上げ中も
///    入力を開けた結果、これがそのまま 1 つの会話ターンになってしまった
/// 2. **会話のキャッチボールにならない短い返事**（「Yes」「Thank you」「And you?」）。
///    Chobi が真面目に返事を組み立てるだけで、練習にならない
/// 3. **単発の間投詞**（「No」「Wait」）。それ自体は中身が無く、続きを言ってはじめて意味を持つ
/// 4. **1 語しかない発話**（「Hello」）。語彙リストに無くても、単語ひとつでは
///    キャッチボールにならない。語を足し続けるのではなく語数で切る（`isWorthSending`）
///
/// ノイズはテキストにならないので既存のレベルゲートで落ちるが、**相槌はテキストになる**。
///
/// 判定は文字列しか見ない。**いつ落とすかは呼び出し側**（`TurnBasedVoiceSession`）が決める。
/// 現在は「送信猶予が明けた時点のターン全文」に対して 1 度だけ掛ける
/// （セグメント単位で掛けると "Yes" と "I love it" を一呼吸置いて言ったときに前半だけ消える）。
///
/// **Phase 4 の割り込み確定（読み上げを止めるか）もこの判定を使う**（作者判断 2026-08-04）:
/// **止めるのは「文章を話したとき」だけ**で、「Wait」「Um」の単発では止めない。
/// ＝ partial が相槌語だけで構成されているうちは止めず、相槌語でない語が 1 つ出た時点で止める。
/// ただし `i` は例外にすること — 文頭に立つ語なので、`I think—` で止めるには
/// 「相槌語でない 2 語目（think）」を待っていられない（実測: 2 語は中央値 2.1 秒）。
enum BackchannelFilter {
    /// 会話ターンとして送る価値があるか（`TurnBasedVoiceSession` が commit 直前に 1 度だけ呼ぶ）。
    ///
    /// - 相槌・決まり文句だけ → false
    /// - **語数が足りない → false**。"Hello" のように相槌リストに無い語でも、単語ひとつでは
    ///   会話のキャッチボールにならない。リストを足し続けるのではなく**語数で切る**
    ///   （英会話の練習として、単語で済ませずに文で言い直してもらう）
    ///
    /// 日本語は分かち書きされないので 1 トークンになりやすく、たいてい落ちる。
    /// 会話は英語のみ（CLAUDE.md）なので、これは意図した副作用。
    ///
    /// - Parameter minimumWordCount: 会話ターンとして送るのに必要な最小語数。
    ///   管理画面「音声入力」で変えられる（既定は `defaultMinimumTurnWordCount`）
    static func isWorthSending(
        _ text: String, minimumWordCount: Int = defaultMinimumTurnWordCount
    ) -> Bool {
        let tokens = normalizedTokens(text)
        guard tokens.count >= minimumWordCount else { return false }
        return !isBackchannel(text)
    }

    /// 会話ターンとして送るのに必要な最小語数の既定（作者判断 2026-08-04）。
    /// **既定値はここが正**で、管理画面の保存は既定と違うときだけ行う。
    static let defaultMinimumTurnWordCount = 3

    /// 決まり文句そのもの、または全トークンが相槌語なら true
    /// （空文字は false = 通常の空セグメント処理に任せる）。
    ///
    /// 1 語でも相槌語でないものが混ざれば false。つまり "Yeah I do a similar thing" は
    /// 先頭が "yeah" でも**落ちない**。相槌だけを並べた "yeah yeah" は落ちる。
    static func isBackchannel(_ text: String) -> Bool {
        let tokens = normalizedTokens(text)
        guard !tokens.isEmpty else { return false }
        if phrases.contains(tokens.joined(separator: " ")) { return true }
        return tokens.allSatisfy(words.contains)
    }

    /// 「文章を話し始めた」と言えるか（Phase 4 の割り込み確定）。
    /// **Chobi の読み上げを止めるのは、こちらが文章を話したときだけ**にするための判定で、
    /// 相槌語だけで構成されているうちは false（「Um」「Wait」の単発では止めない）。
    ///
    /// 途中経過（partial）に対して毎回呼ばれるので、**1 語目から判断できる**必要がある。
    /// そのため `i` は相槌語に入っていても**中身として数える** — 文頭に立つ語なので、
    /// `I think—` で止めるのに 2 語目（think）を待つと実測で中央値 2.1 秒かかって遅すぎる。
    static func startsSentence(_ text: String) -> Bool {
        let tokens = normalizedTokens(text)
        guard !tokens.isEmpty else { return false }
        // 「Thank you」のように決まり文句として落とす言い回しでは止めない
        // （止めても直後にターンが破棄され、Chobi が黙ったまま何も返らない形になる）
        if phrases.contains(tokens.joined(separator: " ")) { return false }
        return tokens.contains { !words.contains($0) || sentenceStarters.contains($0) }
    }

    /// 相槌語だが、**割り込み判定では文の始まりとして扱う**語。
    private static let sentenceStarters: Set<String> = ["i"]

    /// 小文字化し、記号（`.` `,` `!` `?` `'` `-` `…` `。` `、` など）を区切りに変えて分割する。
    /// STT は終止記号をほとんど返さない（実測 2/9）ので、記号の有無に依らず同じ判定にする。
    /// ハイフンを区切りにするのは "uh-huh" / "mm-hmm" を語の並びとして拾うため。
    static func normalizedTokens(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// 語の組み合わせでしか判定できない決まり文句。**全文一致**なので、
    /// ここに "you" を置いても "Thank you for the tip" は落ちない
    /// （`words` に "you" を入れるとそれが落ちてしまうので、こちら側に置く）。
    private static let phrases: Set<String> = [
        "thank you", "thank you very much", "thank you so much",
        "thanks a lot", "thanks so much",
        "you too", "same to you",
        "no problem", "not at all",
        // 相手に振り返すだけの問い返し。それ自体は英語の練習にならないので落とす
        // （聞き返したいときは "And you? What do you do?" のように続ける）
        "you", "and you", "how about you", "what about you", "and yourself",
    ]

    /// 相槌語・単発の間投詞。
    /// **続きがあれば落ちない**（"No I don't think so" は "think" 等が混ざるので通る）ので、
    /// ここに "no" / "wait" を入れても意思表示そのものを失うわけではない。
    private static let words: Set<String> = [
        // 英語: 息継ぎ・つなぎ
        "um", "umm", "uhm", "uh", "uhh", "er", "erm",
        "mm", "mmm", "mhm", "hm", "hmm", "hmmm", "huh",
        "ah", "aha", "ha", "haha", "oh", "ooh", "wow",
        // 英語: 同意・理解の相槌と、返事だけで終わる短い応答
        "yeah", "yea", "yep", "yup", "yes", "ok", "okay", "alright",
        "right", "sure", "true", "exactly", "totally", "indeed", "really",
        "i", "see", "know", "got", "gotcha", "nice", "cool", "great",
        "thanks", "thank",
        // 単発の間投詞（続きを言ってはじめて意味を持つ）
        "no", "nope", "nah", "wait", "stop", "sorry", "well", "anyway",
        // つなぎ語。単体では中身が無く、これだけでは読み上げも止めない
        "and", "but", "so",
        // 日本語（英会話中でも口をついて出る）
        "うん", "うんうん", "はい", "ええ", "そう", "そうそう", "そっか", "そうか",
        "なるほど", "いいね", "へえ", "へー", "ほんと", "ほんとに", "たしかに",
        "あー", "ああ", "えー", "おお", "おー", "すごい", "わかる", "だよね",
        // 日本語は分かち書きされないので、決まり文句も 1 トークンとしてここに置く
        "ありがとう", "ありがとうございます", "どうも", "どういたしまして",
        "わかりました", "そうですね", "いいですね",
        "ううん", "いや", "待って", "ちょっと待って", "ごめん", "すみません",
    ]
}
