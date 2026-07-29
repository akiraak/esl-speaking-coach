import Foundation

/// トークルームの練習モード（docs/plans/word-practice-mode.md）。
/// 会話モードは従来どおりのトピック雑談、単語モードは 1 語を Chobi（先生）と
/// Naruko（学習者と一緒に学ぶ生徒）で練習する。
///
/// `rawValue` は UserDefaults（`chatRoomPracticeMode`）と SwiftData
/// （`ChatSessionRecord.modeRawValue`）にそのまま保存するので、既存の値は変えない。
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

    /// 開始の制御メッセージのキー（`[New topic: X]` / `[New word: X]`）。
    var openingControlKey: String {
        switch self {
        case .conversation: return "New topic"
        case .word: return "New word"
        }
    }

    /// セッションに渡す system prompt。会話用は 1 文字も変えない（プロンプトキャッシュ維持）。
    var systemPrompt: String {
        switch self {
        case .conversation: return CoachSystemPrompt.text
        case .word: return WordCoachSystemPrompt.text
        }
    }

    /// 開始メッセージに記憶ノート（`[Memory: ...]`）を混ぜるか。
    /// 単語モードは混ぜない ―― ノートは身の回りの事実を貯めるもので 1 語の練習には効かず、
    /// 先頭が長くなるぶんレイテンシと料金だけを食うため（更新もしないので対称）。
    var injectsMemoryNote: Bool {
        switch self {
        case .conversation: return true
        case .word: return false
        }
    }

    /// 学習者の goodbye（台本の制御行 `[end]`）でセッションを終わらせるか。
    /// 単語モードは終了ボタンだけで終わり、学習者が止めるまで練習を続ける。
    var endsOnGoodbye: Bool {
        switch self {
        case .conversation: return true
        case .word: return false
        }
    }

    /// 切り替え先（2 値なのでヘッダのピルはメニューを出さずトグルする）。
    var toggled: PracticeMode {
        switch self {
        case .conversation: return .word
        case .word: return .conversation
        }
    }

    /// 永続化した値の復元（未知・未保存は会話モード）。
    init(storedValue: String?) {
        self = storedValue.flatMap(PracticeMode.init(rawValue:)) ?? .conversation
    }
}
