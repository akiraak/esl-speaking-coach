#if DEBUG
import Foundation

/// シミュレータでの動作確認用。起動引数で Keychain の API キーを操作する。
/// 例: xcrun simctl launch booted com.akiraak.EslSpeakingCoach -seed-anthropic-key dummy
enum DebugLaunchArguments {
    private static let keyAccounts: [(seedFlag: String, deleteFlag: String, account: String)] = [
        ("-seed-anthropic-key", "-delete-anthropic-key", KeychainStore.anthropicAPIKeyAccount),
        ("-seed-openai-key", "-delete-openai-key", KeychainStore.openAIAPIKeyAccount),
        ("-seed-gemini-key", "-delete-gemini-key", KeychainStore.geminiAPIKeyAccount),
        ("-seed-wordbook-key", "-delete-wordbook-key", KeychainStore.wordBookAPISecretAccount),
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

    /// 起動時に固定候補「話しかける」でセッションを自動開始する
    /// （権限 → STT モデル → マイクの起動パス確認用。AI の開始ターンは出ないので -send-text から始まる）。
    static var shouldStartConversation: Bool {
        ProcessInfo.processInfo.arguments.contains("-start-conversation")
    }

    /// トピックカードの候補が揃ったら 1 件目を選んで開始する。
    /// カード経由でしか通らない導線（候補の持ち越し）をシミュレータで確認するため。
    /// 単語モードでは「前に練習した語」ピルの 1 件目を選んで開始する（再練習の導線の確認）。
    static var shouldStartFromTopicCard: Bool {
        ProcessInfo.processInfo.arguments.contains("-start-from-card")
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

    /// 起動時に指定の単語で単語練習セッションを自動開始する（`-practice-mode word` と併用する）。
    /// 例: -practice-mode word -start-word "get around to"
    static var startWord: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-start-word"), index + 1 < args.count else {
            return nil
        }
        return args[index + 1]
    }

    /// -send-text をすべて送り終えたあと、終了ボタンと同じ導線でセッションを終了する。
    /// 単語モードは goodbye で終わらないため、E2E から終了を起こす手段として要る。
    static var shouldEndSession: Bool {
        ProcessInfo.processInfo.arguments.contains("-end-session")
    }

    /// 練習モード指定（保存はせずその起動のあいだだけ上書きする）。
    /// 例: -practice-mode word / -practice-mode conversation
    static var practiceModeOverride: PracticeMode? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-practice-mode"), index + 1 < args.count else {
            return nil
        }
        return PracticeMode(rawValue: args[index + 1])
    }

    /// TTS プロバイダ指定。例: -tts-provider gemini / -tts-provider openai
    static var ttsProviderOverride: TTSProvider? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-tts-provider"), index + 1 < args.count else { return nil }
        return TTSProvider(rawValue: args[index + 1])
    }

    /// 診断ログのクラッシュ記録が生きているかを確かめるためのわざと落とす起動引数。
    /// 例: -crash-test exception（Objective-C 例外）/ -crash-test fatal（Swift の実行時エラー）
    /// 起動 3 秒後に落とす（ログの初期化と画面表示を跨いだ状態を模す）。
    static func scheduleCrashTestIfNeeded() {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-crash-test") else { return }
        let kind = index + 1 < args.count ? args[index + 1] : "exception"
        DiagnosticsLog.record("crash-test: \(kind) を 3 秒後に発生させます")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if kind == "fatal" {
                fatalError("診断ログのクラッシュ記録テスト")
            }
            NSException(
                name: NSExceptionName("DiagnosticsCrashTest"),
                reason: "診断ログのクラッシュ記録テスト", userInfo: nil
            ).raise()
        }
    }

    /// 起動時に単語帳ピッカーを開く（シミュレータでの表示確認用。`-practice-mode word` と併用）。
    /// 例: -practice-mode word -open-wordbook
    static var shouldOpenWordBookPicker: Bool {
        ProcessInfo.processInfo.arguments.contains("-open-wordbook")
    }

    /// 単語帳ピッカーを検索済みの状態で開く（サーバ検索 `q` の E2E 用）。
    /// 例: -open-wordbook -wordbook-query "get"
    static var wordBookInitialQuery: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-wordbook-query"), index + 1 < args.count else {
            return nil
        }
        return args[index + 1]
    }

    /// 単語帳ピッカーの読み込み完了後、先頭の語を選んだ扱いにする
    /// （シートを閉じてセッション開始する導線の E2E 用）。
    static var shouldPickFirstWordBookWord: Bool {
        ProcessInfo.processInfo.arguments.contains("-pick-first-wordbook-word")
    }

    /// 単語帳ピッカー表示後にその語の詳細画面を自動で push する（詳細表示の E2E 用）。
    /// 例: -practice-mode word -open-wordbook -wordbook-detail disability
    static var wordBookDetailWord: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-wordbook-detail"), index + 1 < args.count else {
            return nil
        }
        return args[index + 1]
    }

    /// 単語帳 API の base URL を上書きする（ローカル backend での E2E 用。リリースでは常に本番）。
    /// 例: -wordbook-base-url http://localhost:3005
    static var wordBookBaseURLOverride: URL? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-wordbook-base-url"), index + 1 < args.count else {
            return nil
        }
        return URL(string: args[index + 1])
    }

    /// 起動時に管理画面を開く（シミュレータでの表示確認用）。
    /// 例: -open-admin / -open-admin 料金 / -open-admin 診断（タブ名は AdminView.Tab の表示名）
    static var shouldOpenAdmin: Bool {
        ProcessInfo.processInfo.arguments.contains("-open-admin")
    }

    /// タブ指定が無い / 不明な名前なら会話タブで開く。
    static var adminInitialTab: AdminView.Tab {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-open-admin"), index + 1 < args.count else {
            return .sessions
        }
        return AdminView.Tab(rawValue: args[index + 1]) ?? .sessions
    }
}
#endif
