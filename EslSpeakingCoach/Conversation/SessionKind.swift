import Foundation

/// セッションの種別（会話 / 単語 / クイズ。docs/specs/word-practice.md）。
/// UI の練習モード（`PracticeMode`）とは独立で、クイズは UI モード = 単語のまま
/// 単語カード内の導線から `quiz` のセッションとして始まる
/// （docs/plans/archive/quiz-in-word-mode.md）。セッションの振る舞い
/// （system prompt・開始の制御メッセージ・記憶ノート・終わり方）と、
/// セッションに紐づく文言（終了ボタン・一覧の印）はすべてこの型が持つ。
///
/// `rawValue` は SwiftData（`ChatSessionRecord.modeRawValue`）にそのまま保存するので、
/// 既存の値は変えない。
enum SessionKind: String, Sendable, CaseIterable {
    case conversation
    case word
    case quiz

    /// 永続化した値の復元（未知・未保存は会話）。quiz は quiz のまま復元する
    /// （既存レコードを化けさせない。quiz→word の正規化は UI モード側の
    /// `PracticeMode(storedValue:)` だけが行う）。
    init(storedValue: String?) {
        self = storedValue.flatMap(SessionKind.init(rawValue:)) ?? .conversation
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
    /// 単語・クイズは使わない ―― ノートは身の回りの事実を貯めるもので語の練習には効かず、
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
    /// 会話は学習者の goodbye で、クイズは全語出題後の締め（と goodbye）で
    /// プロンプトが `[end]` を出す。単語は終了ボタンだけで終わり、
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

    /// 管理画面のセッション一覧でタイトルに前置する印（会話は無印）。
    /// 単語・クイズのセッションは topicTitle が語そのものなので、印が無いと区別できない。
    var sessionListMarker: String? {
        switch self {
        case .conversation: return nil
        case .word: return "📖"
        case .quiz: return "🎯"
        }
    }
}
