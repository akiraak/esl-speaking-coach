import Foundation

/// AI 2 キャラの固定定義（docs/specs/conversation-design.md）。
/// 名前・人格は system prompt 側、ここでは台本タグと TTS voice / スタイルを持つ。
/// 設定画面での編集は将来検討のため、アプリ内定義の固定値とする。
enum ChatCharacter: String, CaseIterable, Sendable, Identifiable {
    /// ホスト役。会話を回し進行を担当（会話中の訂正・指導はしない。指導はセッション後フィードバックのみ）
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
            // "calm" が話速を引っ張っていたので "lively" に替え、速さの指示を足してある
            // （実測 2.57 → 2.87 words/sec。docs/plans/archive/chobi-voice-speed.md）
            return SpeechStyle(
                voice: "Leda",
                styleInstruction: """
                    Read aloud in a warm, lively, gently cheerful voice, like a friendly teacher \
                    chatting with a student. Speak at a brisk, natural conversational pace, \
                    without dragging out words:
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
