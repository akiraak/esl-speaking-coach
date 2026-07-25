#if DEBUG
import Foundation

/// シミュレータでの動作確認用。起動引数で Keychain の API キーを操作する。
/// 例: xcrun simctl launch booted com.akiraak.EslSpeakingCoach -seed-anthropic-key dummy
enum DebugLaunchArguments {
    private static let keyAccounts: [(seedFlag: String, deleteFlag: String, account: String)] = [
        ("-seed-anthropic-key", "-delete-anthropic-key", KeychainStore.anthropicAPIKeyAccount),
        ("-seed-openai-key", "-delete-openai-key", KeychainStore.openAIAPIKeyAccount),
        ("-seed-gemini-key", "-delete-gemini-key", KeychainStore.geminiAPIKeyAccount),
    ]

    static func apply() {
        let args = ProcessInfo.processInfo.arguments
        let keychain = KeychainStore()
        for entry in keyAccounts {
            if let index = args.firstIndex(of: entry.seedFlag), index + 1 < args.count {
                try? keychain.save(args[index + 1], account: entry.account)
            }
            if args.contains(entry.deleteFlag) {
                try? keychain.delete(account: entry.account)
            }
        }
    }

    /// 起動時に Free talk セッションを自動開始する（権限 → STT モデル → マイクの起動パス確認用）。
    static var shouldStartConversation: Bool {
        ProcessInfo.processInfo.arguments.contains("-start-conversation")
    }

    /// セッションが listening になるたびに、指定順で 1 つずつ user ターンとして自動送信する。
    /// 複数指定で複数ターンの会話を自動再現できる（フィードバック生成の E2E 確認用）。
    /// 例: -start-conversation -send-text "Hello" -send-text "Goodbye, see you!"
    static var autoSendTexts: [String] {
        let args = ProcessInfo.processInfo.arguments
        var texts: [String] = []
        var index = 0
        while index < args.count {
            if args[index] == "-send-text", index + 1 < args.count {
                texts.append(args[index + 1])
                index += 2
            } else {
                index += 1
            }
        }
        return texts
    }

    /// TTS プロバイダ指定。例: -tts-provider gemini / -tts-provider openai
    static var ttsProviderOverride: TTSProvider? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-tts-provider"), index + 1 < args.count else { return nil }
        return TTSProvider(rawValue: args[index + 1])
    }

    /// 起動時に管理画面を開く（シミュレータでの表示確認用）。
    /// 例: -open-admin / -open-admin usage（料金タブで開く）
    static var shouldOpenAdmin: Bool {
        ProcessInfo.processInfo.arguments.contains("-open-admin")
    }

    static var adminOpensOnUsageTab: Bool {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-open-admin"), index + 1 < args.count else { return false }
        return args[index + 1] == "usage"
    }
}
#endif
