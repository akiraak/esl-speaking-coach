import AVFAudio
import Foundation

/// 出力をどこへ流すかの判定と、現在の経路の要約
/// （docs/plans/earphone-audio-route.md）。
///
/// 経路の指定に `.defaultToSpeaker` を**使わない**のが要点。
/// `AVAudioSessionTypes.h` によると PlayAndRecord での `.defaultToSpeaker` は
/// 「Speaker (instead of Receiver) へ流す」オプションで、Bluetooth と併用すると
/// 出力を内蔵スピーカーへ引き寄せてしまう（イヤフォンから鳴らない原因）。
/// 代わりに「**内蔵レシーバー（受話口）しか無いときだけ**スピーカーへ寄せる」を
/// 経路変更のたびに評価する形にする。
///
/// ハードウェアなしでテストできるよう、判定は純関数に切り出してある。
enum AudioRoutePolicy {
    /// 会話セッションのカテゴリオプション。
    ///
    /// - `.allowBluetoothHFP` は `mode: .voiceChat` で暗黙に立つが、依存を明示するため書く。
    ///   AirPods を**入出力とも**使うにはこれが要る（HFP = マイク付き双方向プロファイル）
    /// - `.allowBluetoothA2DP` はマイクを持たない Bluetooth ヘッドホン / スピーカーのため。
    ///   HFP と A2DP の両対応機（AirPods 等）はヘッダ記載どおり **HFP が優先**されるので、
    ///   「マイクも AirPods」という望ましい形は崩れない
    /// - 音質は HFP（AirPods は mSBC 16kHz）に落ちるが、マイクとの同時使用が必須な以上避けられない
    static let categoryOptions: AVAudioSession.CategoryOptions = [
        .allowBluetoothHFP, .allowBluetoothA2DP, .allowAirPlay,
    ]

    /// 出力が**本体内蔵（受話口 / スピーカー）だけ**のときに true。
    /// このときだけ `overrideOutputAudioPort(.speaker)` して、端末を耳に当てずに聞けるようにする。
    ///
    /// イヤフォン・Bluetooth・AirPlay 等が 1 つでも居ればオーバーライドせず、
    /// OS が選んだ経路をそのまま使う。空（まだ経路が確定していない）のときも触らない。
    ///
    /// **内蔵スピーカーでも true を返すのが要点**（docs/plans/archive/speaker-no-audio.md）。
    /// オーバーライドが効くと出力は `builtInSpeaker` になるので、「スピーカーなら不要」と
    /// 判定すると自分のオーバーライドを自分で取り消し、受話口 ⇄ スピーカーの往復が始まる。
    /// その往復で AVAudioEngine が止まり、読み上げが一切鳴らなくなっていた。
    static func needsSpeakerOverride(outputPortTypes: [AVAudioSession.Port]) -> Bool {
        guard !outputPortTypes.isEmpty else { return false }
        return outputPortTypes.allSatisfy { $0 == .builtInReceiver || $0 == .builtInSpeaker }
    }

    /// 診断ログ / 会話ログ用の 1 行要約。「なぜ聞こえないか」を実機でその場で読むためのもの。
    static func describe(_ route: AVAudioSessionRouteDescription, sampleRate: Double) -> String {
        let outputs = describePorts(route.outputs)
        let inputs = describePorts(route.inputs)
        return "出力=\(outputs) 入力=\(inputs) \(Int(sampleRate))Hz"
    }

    static func describePorts(_ ports: [AVAudioSessionPortDescription]) -> String {
        guard !ports.isEmpty else { return "なし" }
        return ports
            .map { "\($0.portType.rawValue)(\($0.portName))" }
            .joined(separator: "+")
    }
}
