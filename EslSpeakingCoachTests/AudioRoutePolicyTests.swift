import AVFAudio
import Testing

@testable import EslSpeakingCoach

/// 出力経路の判定（docs/plans/earphone-audio-route.md）。
/// 実機のオーディオ経路に触らず判定だけを検証する。
struct AudioRoutePolicyTests {
    @Test("受話口だけならスピーカーへ寄せる")
    func builtInReceiverNeedsOverride() {
        #expect(AudioRoutePolicy.needsSpeakerOverride(outputPortTypes: [.builtInReceiver]))
    }

    @Test("Bluetooth HFP（AirPods）が居るならオーバーライドしない")
    func bluetoothHFPKeepsRoute() {
        #expect(!AudioRoutePolicy.needsSpeakerOverride(outputPortTypes: [.bluetoothHFP]))
    }

    @Test("Bluetooth A2DP（ヘッドホン）が居るならオーバーライドしない")
    func bluetoothA2DPKeepsRoute() {
        #expect(!AudioRoutePolicy.needsSpeakerOverride(outputPortTypes: [.bluetoothA2DP]))
    }

    @Test("有線イヤフォンならオーバーライドしない")
    func headphonesKeepRoute() {
        #expect(!AudioRoutePolicy.needsSpeakerOverride(outputPortTypes: [.headphones]))
    }

    @Test("既にスピーカーならオーバーライド不要")
    func builtInSpeakerNeedsNoOverride() {
        #expect(!AudioRoutePolicy.needsSpeakerOverride(outputPortTypes: [.builtInSpeaker]))
    }

    @Test("受話口と他の経路が混ざっていればオーバーライドしない")
    func mixedRouteKeepsRoute() {
        #expect(!AudioRoutePolicy.needsSpeakerOverride(
            outputPortTypes: [.builtInReceiver, .headphones]))
    }

    @Test("経路が未確定（空）なら何もしない")
    func emptyRouteNeedsNoOverride() {
        #expect(!AudioRoutePolicy.needsSpeakerOverride(outputPortTypes: []))
    }

    @Test("カテゴリオプションに defaultToSpeaker を含めない（イヤフォンから鳴らなくなる原因）")
    func categoryOptionsExcludeDefaultToSpeaker() {
        #expect(!AudioRoutePolicy.categoryOptions.contains(.defaultToSpeaker))
    }

    @Test("Bluetooth の入出力を許可している")
    func categoryOptionsAllowBluetooth() {
        #expect(AudioRoutePolicy.categoryOptions.contains(.allowBluetoothHFP))
        #expect(AudioRoutePolicy.categoryOptions.contains(.allowBluetoothA2DP))
    }

    @Test("ポートが無ければ「なし」と表示する")
    func describeEmptyPorts() {
        #expect(AudioRoutePolicy.describePorts([]) == "なし")
    }
}
