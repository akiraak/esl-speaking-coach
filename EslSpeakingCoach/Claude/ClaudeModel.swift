import Foundation

/// 管理画面から選べる Claude のモデル（docs/plans/model-selection-in-admin.md Phase 2）。
/// **rawValue はそのまま API の `model` に送る値**（日付サフィックスは付けない。CLAUDE.md の規約）。
/// 単価は `AIPricing` が単一の正なのでここには持たない。
enum ClaudeModel: String, CaseIterable, Identifiable, Sendable {
    case sonnet5 = "claude-sonnet-5"
    case opus5 = "claude-opus-5"
    case haiku45 = "claude-haiku-4-5"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sonnet5: return "Sonnet 5"
        case .opus5: return "Opus 5"
        case .haiku45: return "Haiku 4.5"
        }
    }

    /// `output_config.effort` を受け付けるか。**haiku-4-5 は送ると 400 になる**。
    /// 各クライアントはこのフラグだけを見て effort を出し入れする（判定はここ 1 箇所）。
    var supportsEffort: Bool {
        switch self {
        case .sonnet5, .opus5: return true
        case .haiku45: return false
        }
    }

    /// プロンプトキャッシュが効く最小プレフィックス（トークン。2026-08-03 時点の各モデルの値）。
    /// **これ未満の system prompt に cache_control を付けてもエラーは出ず、黙って効かない**
    /// （2 キャラ台本の system prompt は約 2,000 トークン = haiku-4-5 では効かない）。
    var cacheMinimumPromptTokens: Int {
        switch self {
        case .opus5: return 512
        case .sonnet5: return 1024
        case .haiku45: return 4096
        }
    }

    /// 会話ターンの max_tokens。**thinking と本文で共有する予算**なので、thinking が既定 ON の
    /// opus-5 は 1024 だと本文が途中で切れうる。4096 は暫定値（実機で計測して詰める）。
    var turnMaxTokens: Int {
        switch self {
        case .opus5: return 4096
        case .sonnet5, .haiku45: return 1024
        }
    }
}

/// モデルを選べる Claude の経路（課金 7 経路のうち Claude を使う 5 つ）。
/// **既定モデルと effort の単一の正**。各クライアントの既定値もここを参照する。
/// TTS / STT は Phase 3 で足す。
enum ClaudeRoute: String, CaseIterable, Identifiable, Sendable {
    case conversationTurn
    case topicSuggestion
    case sessionFeedback
    case memoryUpdate
    case translation

    var id: String { rawValue }

    /// 対応する課金経路（保存キー・料金画面の種別と 1:1 で対応させる）。
    var kind: AIUsageEvent.Kind {
        switch self {
        case .conversationTurn: return .conversationTurn
        case .topicSuggestion: return .topicSuggestion
        case .sessionFeedback: return .sessionFeedback
        case .memoryUpdate: return .memoryUpdate
        case .translation: return .translation
        }
    }

    var title: String { kind.label }

    var defaultModel: ClaudeModel {
        switch self {
        // 短文の英日翻訳に sonnet は過剰なので haiku（docs/plans/message-translation.md）
        case .translation: return .haiku45
        case .conversationTurn, .topicSuggestion, .sessionFeedback, .memoryUpdate: return .sonnet5
        }
    }

    /// この経路が要求する effort（nil = 送らない）。モデルが非対応なら送信時に落とす。
    var effort: String? {
        switch self {
        case .conversationTurn, .topicSuggestion: return "low"
        case .memoryUpdate: return "medium"
        case .sessionFeedback: return "high"
        case .translation: return nil
        }
    }

    /// system prompt に `cache_control` を付けている経路か（キャッシュ最小プレフィックスの注意対象）。
    var usesPromptCache: Bool {
        switch self {
        case .conversationTurn, .sessionFeedback, .memoryUpdate: return true
        case .topicSuggestion, .translation: return false
        }
    }

    /// 反映のタイミング（管理画面の注記）。会話ターンだけセッション開始時に構成へ焼き込まれる。
    var appliesFromNextSession: Bool { self == .conversationTurn }

    /// system prompt のおおよそのトークン数（キャッシュ最小プレフィックスとの比較用）。
    /// 2 キャラ台本は約 2,000 トークン（CLAUDE.md）。実測していない経路は nil にして黙っておく。
    var approximateSystemPromptTokens: Int? {
        self == .conversationTurn ? 2_000 : nil
    }
}

/// Claude リクエストボディの共通部品（JSONSerialization で組み立てる 4 クライアント用）。
enum ClaudeRequestBody {
    /// `output_config` を組み立てる。**effort はモデルが対応しているときだけ入れる**
    /// （haiku-4-5 へ送ると 400。判定は `ClaudeModel.supportsEffort` の 1 箇所）。
    /// structured outputs 前提なので schema は必須（= 戻り値が空になることはない）。
    static func outputConfig(
        model: ClaudeModel, effort: String?, schema: [String: Any]
    ) -> [String: Any] {
        var config: [String: Any] = [
            "format": ["type": "json_schema", "schema": schema]
        ]
        if let effort, model.supportsEffort {
            config["effort"] = effort
        }
        return config
    }
}
