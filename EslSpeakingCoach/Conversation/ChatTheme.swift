import SwiftUI

/// 案 D「ポップ・スタディ」のカラーパレット・形状（docs/specs/screen-layout.md）。
/// ダークモードの配色は未決のため、当面 ChatRoomView 側でライト固定にしている。
enum ChatTheme {
    /// チャット背景（暖色クリーム）
    static let chatBackground = Color(rgb: 0xFDF3E3)
    /// ヘッダ / 入力バー背景
    static let barBackground = Color.white
    static let aiBubble = Color.white
    static let aiText = Color(rgb: 0x45351F)
    /// ユーザー吹き出し（コーラルオレンジ）
    static let userBubble = Color(rgb: 0xF0642F)
    static let userText = Color(rgb: 0xFFF6EF)
    /// ライブ文字起こし
    static let liveBubble = Color(rgb: 0xF0642F).opacity(0.2)
    static let liveText = Color(rgb: 0xB5502A)
    /// アクセント（波形・送信ボタン・カードタイトル・🔊 表示）
    static let accent = Color(rgb: 0xF0642F)
    static let cardBorder = Color(rgb: 0x785028).opacity(0.12)
    static let topicPill = Color(rgb: 0xFBEEDD)
    static let topicPillSelected = Color(rgb: 0xFFE1D2)
    static let topicPillSelectedText = Color(rgb: 0xCF4A17)
    static let systemText = Color(rgb: 0x96775C)
    static let systemPill = Color(rgb: 0x785028).opacity(0.10)
    static let nameLabel = Color(rgb: 0xA08464)
    static let inputField = Color(rgb: 0xF7ECDC)
    static let bubbleShadow = Color(rgb: 0x785028).opacity(0.1)
    /// フィードバックカードの ✓（改善例）。✗ 側は liveText を使う
    static let feedbackGood = Color(rgb: 0x3E9B63)

    /// 吹き出しの角丸（しっぽ側のみ 6pt）
    static let bubbleRadius: CGFloat = 20
    static let bubbleTailRadius: CGFloat = 6
    static let cardRadius: CGFloat = 20
}

extension ChatCharacter {
    /// キャラのテーマ色（管理画面の話者名などテキスト用。アバター本体は画像アセット）。
    var avatarColor: Color {
        switch self {
        case .chobi: return Color(rgb: 0xEF5DA8)
        case .naruko: return Color(rgb: 0x6FCF97)
        }
    }
}

extension Color {
    /// 0xRRGGBB 形式のリテラルから生成する。
    init(rgb: UInt32) {
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255)
    }
}
