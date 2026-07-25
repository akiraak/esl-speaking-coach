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
}
#endif
