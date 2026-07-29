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

    /// オーバーライドが効くと出力は builtInSpeaker になる。ここで false を返すと
    /// 自分のオーバーライドを自分で取り消し、受話口 ⇄ スピーカーの往復が始まって
    /// AVAudioEngine が止まる（= 読み上げが一切鳴らない。docs/plans/archive/speaker-no-audio.md）
    @Test("内蔵スピーカーでもスピーカー指定を維持する（往復防止）")
    func builtInSpeakerKeepsOverride() {
        #expect(AudioRoutePolicy.needsSpeakerOverride(outputPortTypes: [.builtInSpeaker]))
        // 冪等: 判定 → オーバーライド → 再判定 で結論が変わらない
        #expect(AudioRoutePolicy.needsSpeakerOverride(outputPortTypes: [.builtInReceiver])
            == AudioRoutePolicy.needsSpeakerOverride(outputPortTypes: [.builtInSpeaker]))
    }

    @Test("AirPlay が居るならオーバーライドしない")
    func airPlayKeepsRoute() {
        #expect(!AudioRoutePolicy.needsSpeakerOverride(outputPortTypes: [.airPlay]))
    }

    @Test("内蔵スピーカーと外部が混ざっていればオーバーライドしない")
    func speakerWithExternalKeepsRoute() {
        #expect(!AudioRoutePolicy.needsSpeakerOverride(
            outputPortTypes: [.builtInSpeaker, .bluetoothA2DP]))
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
