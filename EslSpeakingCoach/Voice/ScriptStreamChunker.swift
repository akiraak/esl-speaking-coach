import Foundation

/// 台本 1 発話のうち TTS へ流せる 1 文。
struct ScriptSentence: Equatable, Sendable {
    /// ターン内の発話（= 台本の行 = 吹き出し）通し番号。0 始まり
    let utteranceIndex: Int
    let speaker: ChatCharacter
    let text: String
}

/// 2 キャラ台本のストリーミングパーサ（conversation-design.md「ストリーミングパースと読み上げ」）。
/// SSE デルタを逐次受け、行頭タグ（`Chobi: ` / `Naruko: `）で speaker を確定し、
/// 文境界で `(発話 index, speaker, 文)` を切り出す。
///
/// - 改行 = 発話境界。タグはデルタ境界で分割されても行バッファで吸収する
/// - タグの無い行は直前の speaker（ターン先頭なら Chobi）に帰属させる
/// - `[end]` は表示・読み上げ対象から除去し `endDetected` を立てる（単独行が原則だが行内出現も吸収）
struct ScriptStreamChunker {
    /// goodbye 自動終了の制御行 `[end]` を検知した。
    private(set) var endDetected = false
    /// これまでに確定した発話数（= 最終 utteranceIndex + 1）。
    private(set) var utteranceCount = 0

    /// 現在の行の、タグ確定前の先頭バッファ + タグ確定後の未処理分。
    private var input = ""
    /// 現在の行のタグ判定が済んだか（済むまで文の切り出しはしない）。
    private var lineDetermined = false
    /// 現在の行がすでに発話として index を割り当てたか（空行・除去のみの行に index を消費させない）。
    private var lineHasUtterance = false
    private var currentSpeaker: ChatCharacter = .chobi
    private var sentenceChunker = SentenceChunker()

    private static let tags: [(prefix: String, speaker: ChatCharacter)] = [
        ("Chobi:", .chobi),
        ("Naruko:", .naruko),
    ]

    /// デルタを追加し、確定した文を（0 個以上）返す。
    mutating func consume(_ delta: String) -> [ScriptSentence] {
        input += delta
        var out: [ScriptSentence] = []
        while !input.isEmpty {
            if !lineDetermined {
                if let match = Self.matchTag(input) {
                    currentSpeaker = match.speaker
                    input.removeFirst(match.length)
                } else if Self.couldBecomeTag(input) {
                    break  // タグがデルタ境界で割れている可能性があるため続きを待つ
                }
                // タグ無し行は currentSpeaker のまま（フォールバック）
                lineDetermined = true
            }
            if let newlineIndex = input.firstIndex(of: "\n") {
                let lineRest = String(input[..<newlineIndex])
                input = String(input[input.index(after: newlineIndex)...])
                emit(sentenceChunker.consume(lineRest), into: &out)
                if let rest = sentenceChunker.flush() {
                    emit([rest], into: &out)
                }
                lineDetermined = false
                lineHasUtterance = false
            } else {
                emit(sentenceChunker.consume(input), into: &out)
                input = ""
            }
        }
        return out
    }

    /// ストリーム終了時に残りを吐き出す。
    mutating func flush() -> [ScriptSentence] {
        var out: [ScriptSentence] = []
        if !input.isEmpty {
            // タグ待ちのまま終わった行を解決する（完全一致すればタグ、そうでなければ本文扱い）
            if !lineDetermined {
                if let match = Self.matchTag(input) {
                    currentSpeaker = match.speaker
                    input.removeFirst(match.length)
                }
                lineDetermined = true
            }
            emit(sentenceChunker.consume(input), into: &out)
            input = ""
        }
        if let rest = sentenceChunker.flush() {
            emit([rest], into: &out)
        }
        lineDetermined = false
        lineHasUtterance = false
        return out
    }

    private mutating func emit(_ rawSentences: [String], into out: inout [ScriptSentence]) {
        for raw in rawSentences {
            var text = raw
            if text.contains("[end]") {
                endDetected = true
                text = text
                    .replacingOccurrences(of: "[end]", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
            guard text.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            if !lineHasUtterance {
                lineHasUtterance = true
                utteranceCount += 1
            }
            out.append(ScriptSentence(
                utteranceIndex: utteranceCount - 1, speaker: currentSpeaker, text: text))
        }
    }

    /// 行頭タグの一致。タグ直後の空白 1 個までをタグの一部として読み飛ばす。
    private static func matchTag(_ line: String) -> (speaker: ChatCharacter, length: Int)? {
        for tag in tags where line.hasPrefix(tag.prefix) {
            var length = tag.prefix.count
            let after = line.index(line.startIndex, offsetBy: length)
            if after < line.endIndex, line[after] == " " {
                length += 1
            }
            return (tag.speaker, length)
        }
        return nil
    }

    /// 続きのデルタ次第でタグになり得る（= タグ文字列の真の接頭辞）。
    private static func couldBecomeTag(_ line: String) -> Bool {
        tags.contains { $0.prefix.count > line.count && $0.prefix.hasPrefix(line) }
    }
}
