import Foundation

/// トークルームの練習モード（docs/specs/word-practice.md / docs/plans/archive/quiz-in-word-mode.md）。
/// 会話モードは従来どおりのトピック雑談、単語モードは 1 語を Chobi（先生）と
/// Naruko（学習者と一緒に学ぶ生徒）で練習する。クイズは独立した UI モードではなく
/// 単語カード内の導線から始まる**セッションの種別**で、練習済みの語から
/// ランダムに選んだ語を Chobi が出題し、思い出す練習をする。
///
/// `rawValue` は UserDefaults（`chatRoomPracticeMode`）と SwiftData
/// （`ChatSessionRecord.modeRawValue`）にそのまま保存するので、既存の値は変えない
/// （保存済みレコードがあるため `.quiz` のケースは消せない）。
enum PracticeMode: String, Sendable, CaseIterable {
    case conversation
    case word
    case quiz

    /// ヘッダのモードピルに出す選択肢（クイズは単語カード内の導線なのでピルには出さない）。
    static let selectableModes: [PracticeMode] = [.conversation, .word]

    /// ヘッダのモードピルに出す短いラベル
    /// （quiz はピルに出ないため到達しないが、switch の網羅性のため残す）。
    var displayName: String {
        switch self {
        case .conversation: return "会話"
        case .word: return "単語"
        case .quiz: return "クイズ"
        }
    }

    /// モードピルのアイコン（SF Symbols。quiz はピルに出ないため到達しない）。
    var symbolName: String {
        switch self {
        case .conversation: return "bubble.left.and.bubble.right"
        case .word: return "character.book.closed"
        case .quiz: return "questionmark.circle"
        }
    }

    /// 開始の制御メッセージのキー（`[New topic: X]` / `[New word: X]` / `[Quiz words: X, Y]`）。
    var openingControlKey: String {
        switch self {
        case .conversation: return "New topic"
        case .word: return "New word"
        case .quiz: return "Quiz words"
        }
    }

    /// セッションに渡す system prompt。会話用は 1 文字も変えない（プロンプトキャッシュ維持）。
    var systemPrompt: String {
        switch self {
        case .conversation: return CoachSystemPrompt.text
        case .word: return WordCoachSystemPrompt.text
        case .quiz: return QuizCoachSystemPrompt.text
        }
    }

    /// 記憶ノートを使うか（開始時の `[Memory: ...]` 注入と、終了時のローリング更新の両方）。
    /// 単語・クイズモードは使わない ―― ノートは身の回りの事実を貯めるもので語の練習には効かず、
    /// 先頭が長くなるぶんレイテンシと料金だけを食う。練習の逐語がノートに入ると
    /// 会話モードの雑談品質も落ちるので、注入と更新の両方を止める。
    var usesMemoryNote: Bool {
        switch self {
        case .conversation: return true
        case .word, .quiz: return false
        }
    }

    /// セッション後フィードバックへ渡す 1 行目のラベル
    /// （`Topic: X` / `Practice word: X` / `Quiz words: X, Y`）。
    /// system prompt は共通のまま、評価の観点だけをこの 1 語で寄せる。
    var feedbackTopicLabel: String {
        switch self {
        case .conversation: return "Topic"
        case .word: return "Practice word"
        case .quiz: return "Quiz words"
        }
    }

    /// 台本の制御行 `[end]` でセッションを終わらせるか。
    /// 会話モードは学習者の goodbye で、クイズモードは全語出題後の締め（と goodbye）で
    /// プロンプトが `[end]` を出す。単語モードは終了ボタンだけで終わり、
    /// 学習者が止めるまで練習を続ける。
    var endsOnGoodbye: Bool {
        switch self {
        case .conversation, .quiz: return true
        case .word: return false
        }
    }

    /// タイムライン下端の終了ボタンの文言（確認アラートは「〜しますか？」を後置する）。
    var endSessionButtonTitle: String {
        switch self {
        case .conversation: return "このトピックを終了"
        case .word: return "この単語を終了"
        case .quiz: return "このクイズを終了"
        }
    }

    /// セッション未開始のとき入力バーに出す案内
    /// （セッション外の UI モードは会話 / 単語だけなので quiz には到達しない）。
    var idlePrompt: String {
        switch self {
        case .conversation: return "トピックカードから話題を選んでスタート"
        case .word: return "カードから練習する単語を入力してスタート"
        case .quiz: return "カードからクイズを始めてスタート"
        }
    }

    /// トピックカードの見出し（クイズ専用カードは廃止したため quiz には到達しない）。
    var topicCardTitle: String {
        switch self {
        case .conversation: return "📌 次のトピック"
        case .word: return "📖 次に練習する単語"
        case .quiz: return "🎯 単語クイズ"
        }
    }

    /// 管理画面のセッション一覧でタイトルに前置する印（会話は無印）。
    /// 単語・クイズのセッションは topicTitle が語そのものなので、印が無いと区別できない。
    var sessionListMarker: String? {
        switch self {
        case .conversation: return nil
        case .word: return "📖"
        case .quiz: return "🎯"
        }
    }

    /// 永続化した値の復元（未知・未保存は会話モード）。
    init(storedValue: String?) {
        self = storedValue.flatMap(PracticeMode.init(rawValue:)) ?? .conversation
    }
}
