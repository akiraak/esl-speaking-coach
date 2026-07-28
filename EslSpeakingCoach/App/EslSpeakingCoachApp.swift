import SwiftUI

@main
struct EslSpeakingCoachApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // クラッシュ時に直前の操作を追えるよう、他の初期化より先に仕掛ける
        DiagnosticsLog.start()
        #if DEBUG
        DebugLaunchArguments.apply()
        DebugLaunchArguments.scheduleCrashTestIfNeeded()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ChatRoomView()
        }
        .onChange(of: scenePhase) { _, phase in
            // 落ちたのか、バックグラウンドで終了させられたのかを後から区別するため
            DiagnosticsLog.record("app: シーン \(phase)")
        }
    }
}
