import SwiftUI

@main
struct EslSpeakingCoachApp: App {
    init() {
        #if DEBUG
        DebugLaunchArguments.apply()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ChatRoomView()
        }
    }
}
