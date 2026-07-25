#if DEBUG
import Foundation

/// シミュレータでの動作確認用。起動引数で Keychain の API キーを操作する。
/// 例: xcrun simctl launch booted com.akiraak.EslSpeakingCoach -seed-anthropic-key dummy
enum DebugLaunchArguments {
    static func apply() {
        let args = ProcessInfo.processInfo.arguments
        let keychain = KeychainStore()
        if let index = args.firstIndex(of: "-seed-anthropic-key"), index + 1 < args.count {
            try? keychain.save(args[index + 1], account: KeychainStore.anthropicAPIKeyAccount)
        }
        if args.contains("-delete-anthropic-key") {
            try? keychain.delete(account: KeychainStore.anthropicAPIKeyAccount)
        }
    }

    /// 起動時に会話画面まで自動遷移する（UI スモークテスト用）。
    static var shouldOpenConversation: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("-open-conversation") || shouldStartConversation
    }

    /// 会話画面を開いてセッションも自動開始する（権限 → STT モデル → マイクの起動パス確認用）。
    static var shouldStartConversation: Bool {
        ProcessInfo.processInfo.arguments.contains("-start-conversation")
    }

    /// セッションが listening になったら、この文字列を user ターンとして自動送信する。
    /// 例: -start-conversation -send-text "Hello coach"
    static var autoSendText: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-send-text"), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}
#endif
