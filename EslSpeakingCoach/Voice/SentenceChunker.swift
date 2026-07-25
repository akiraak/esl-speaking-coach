import Foundation

/// ストリーミングで届くテキストを文単位に切り出す。
/// Claude の SSE デルタを溜め、文が確定するたびに TTS へ流すために使う。
///
/// 境界の規則:
/// - `.` `!` `?`（直後に閉じ引用符・閉じ括弧が続いてもよい）の次が空白なら文境界
/// - 改行はそれ自体が文境界
/// - バッファ末尾の終端記号は境界にしない（"3." の直後に "5" が届く可能性があるため flush まで待つ）
struct SentenceChunker {
    private var buffer = ""

    /// デルタを追加し、確定した文を（0 個以上）返す。
    mutating func consume(_ delta: String) -> [String] {
        buffer += delta
        var sentences: [String] = []
        while let sentence = extractNextSentence() {
            if sentence.contains(where: { $0.isLetter || $0.isNumber }) {
                sentences.append(sentence)
            }
        }
        return sentences
    }

    /// ストリーム終了時に残りを吐き出す。
    mutating func flush() -> String? {
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return rest.isEmpty ? nil : rest
    }

    private mutating func extractNextSentence() -> String? {
        let chars = Array(buffer)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\n" {
                return cut(chars: chars, sentenceEnd: i - 1, remainderStart: i + 1)
            }
            if c == "." || c == "!" || c == "?" {
                var j = i + 1
                while j < chars.count, closingMarks.contains(chars[j]) { j += 1 }
                if j < chars.count, chars[j].isWhitespace {
                    return cut(chars: chars, sentenceEnd: j - 1, remainderStart: j + 1)
                }
                i = j
                continue
            }
            i += 1
        }
        return nil
    }

    private mutating func cut(chars: [Character], sentenceEnd: Int, remainderStart: Int) -> String {
        let sentence = sentenceEnd >= 0 ? String(chars[0...sentenceEnd]) : ""
        let remainder = remainderStart < chars.count ? String(chars[remainderStart...]) : ""
        buffer = String(remainder.drop(while: { $0.isWhitespace }))
        return sentence.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private let closingMarks: Set<Character> = ["\"", "'", "”", "’", ")", "]"]
}
