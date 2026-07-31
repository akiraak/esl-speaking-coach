import Foundation

/// トークルームの UI の練習モード（会話 / 単語。docs/specs/word-practice.md）。
/// ヘッダのピルで選ぶもので、役割は「セッション外の画面（カード・入力バーの案内）が
/// どちらの顔をしているか」だけ。セッションの振る舞い・保存レコードの種別は `SessionKind`
/// が持つ（クイズは UI モードではなくセッション種別。docs/plans/archive/quiz-in-word-mode.md）。
///
/// `rawValue` は UserDefaults（`chatRoomPracticeMode`）にそのまま保存するので、既存の値は変えない。
enum PracticeMode: String, Sendable, CaseIterable {
    case conversation
    case word

    /// ヘッダのモードピルに出す短いラベル。
    var displayName: String {
        switch self {
        case .conversation: return "会話"
        case .word: return "単語"
        }
    }

    /// モードピルのアイコン（SF Symbols）。
    var symbolName: String {
        switch self {
        case .conversation: return "bubble.left.and.bubble.right"
        case .word: return "character.book.closed"
        }
    }

    /// セッション未開始のとき入力バーに出す案内。
    var idlePrompt: String {
        switch self {
        case .conversation: return "トピックカードから話題を選んでスタート"
        case .word: return "カードから練習する単語を入力してスタート"
        }
    }

    /// トピックカードの見出し。
    var topicCardTitle: String {
        switch self {
        case .conversation: return "📌 次のトピック"
        case .word: return "📖 次に練習する単語"
        }
    }

    /// 通常のセッション開始の既定のセッション種別（UI モードと同名）。
    /// クイズだけは単語カード内の導線が明示的に `.quiz` を渡す。
    var defaultSessionKind: SessionKind {
        switch self {
        case .conversation: return .conversation
        case .word: return .word
        }
    }

    /// 永続化した値の復元（未知・未保存は会話モード）。クイズが単語モード内の導線になったため、
    /// 旧バージョンの UI モード保存値 `quiz` は単語モードへ正規化する
    /// （docs/plans/archive/quiz-in-word-mode.md）。
    init(storedValue: String?) {
        if storedValue == "quiz" {
            self = .word
        } else {
            self = storedValue.flatMap(PracticeMode.init(rawValue:)) ?? .conversation
        }
    }
}
