import Foundation

/// 管理画面から選べる STT モデル（docs/plans/model-selection-in-admin.md Phase 3）。
/// **rawValue はそのまま `OpenAITranscriptionConfiguration.model` に入る値**
/// （接続クライアント・VAD の方式・マイクのサンプルレートはこの値から派生する）。
enum STTModel: String, CaseIterable, Identifiable, Sendable {
    /// 既定。クライアント VAD + 手動 commit（2026-07-31 採用。
    /// docs/plans/archive/gpt-live-transcribe-adoption.md）
    case live = "gpt-live-transcribe"
    /// 旧既定。サーバ VAD で常時送信・音声 barge-in あり
    case transcribe4o = "gpt-4o-transcribe"
    /// 検証の結果見送った切替経路（docs/plans/archive/alibaba-voice-models.md）
    case qwenASR = "qwen3-asr-flash-realtime"

    /// **STT 既定の単一の正**（`OpenAITranscriptionConfiguration.model` の既定値もここを見る）。
    static let `default` = STTModel.live

    var id: String { rawValue }

    var label: String {
        switch self {
        case .live: return "gpt-live-transcribe"
        case .transcribe4o: return "gpt-4o-transcribe"
        case .qwenASR: return "Qwen3-ASR"
        }
    }

    /// 接続に要る API キーの Keychain アカウント。
    var keychainAccount: String {
        switch self {
        case .live, .transcribe4o: return KeychainStore.openAIAPIKeyAccount
        case .qwenASR: return KeychainStore.dashScopeAPIKeyAccount
        }
    }

    /// 管理画面に出す挙動の違い（課金の効き方が変わるので選ぶときに効く）。
    var note: String {
        switch self {
        case .live:
            return "クライアント VAD + 手動 commit。発話区間だけ送るので無音・AI 発話中は課金されない"
        case .transcribe4o:
            return "サーバ VAD。マイクを常時送信し、音声での barge-in ができる"
        case .qwenASR:
            return "マイクを 16kHz へ落として送る。実機検証の結果、採用は見送った経路"
        }
    }
}
