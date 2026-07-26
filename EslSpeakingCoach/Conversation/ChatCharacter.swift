import Foundation

/// AI 2 キャラの固定定義（docs/specs/conversation-design.md）。
/// 名前・人格は system prompt 側、ここでは台本タグと TTS voice / スタイルを持つ。
/// 設定画面での編集は将来検討のため、アプリ内定義の固定値とする。
enum ChatCharacter: String, CaseIterable, Sendable, Identifiable {
    /// 先生役。会話を回し、recast / tip を担当
    case chobi
    /// 仲間の生徒役。リアクションと質問で会話に厚みを出す
    case naruko

    var id: String { rawValue }

    /// 表示名 = 台本の行頭タグ名。
    var displayName: String {
        switch self {
        case .chobi: return "Chobi"
        case .naruko: return "Naruko"
        }
    }

    /// 台本直列化時の行頭タグ。
    var scriptTag: String { displayName + ": " }

    /// アバター画像のアセット名（Assets.xcassets）。
    var avatarImageName: String {
        switch self {
        case .chobi: return "chobi-icon"
        case .naruko: return "naruko-icon"
        }
    }

    /// キャラ固有の TTS voice とスタイル前置文（conversation-design.md の確定値）。
    var speechStyle: SpeechStyle {
        switch self {
        case .chobi:
            return SpeechStyle(
                voice: "Leda",
                styleInstruction: """
                    Read aloud in a warm, calm, gently cheerful voice, like a friendly teacher \
                    smiling as she talks:
                    """)
        case .naruko:
            return SpeechStyle(
                voice: "Aoede",
                styleInstruction: """
                    Read aloud in a bright, energetic voice, full of curiosity, like an \
                    enthusiastic student chatting with friends:
                    """)
        }
    }
}
