import AVFAudio
import XCTest

@testable import EslSpeakingCoach

/// live（クライアント VAD）モードの送信ゲート（docs/plans/archive/gpt-live-transcribe-adoption.md Phase 2）。
/// 合成 PCM バッファを `AudioTapRouter.process` に流し、発話区間 + 遡りだけが
/// 正しい境界イベント付きで届くことを検証する。4o 経路（attachRawPCM16）は触っていない。
final class AudioTapRouterGateTests: XCTestCase {
    /// タップ入力を模したフォーマット（実機は 48kHz だが、変換の等価性はレートに依らない）
    private let inputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
    /// STT へ送る形式（TurnBasedVoiceSession.micFormat と同じ）
    private let sttFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)!
    /// 43ms 相当のフレーム数（1032 / 24000 = 0.043）
    private let framesPerBuffer: AVAudioFrameCount = 1032

    /// 一定振幅のバッファ（RMS = 振幅）を作る
    private func makeBuffer(amplitude: Float) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: framesPerBuffer)!
        buffer.frameLength = framesPerBuffer
        let channel = buffer.floatChannelData![0]
        for index in 0..<Int(framesPerBuffer) { channel[index] = amplitude }
        return buffer
    }

    private func process(_ router: AudioTapRouter, amplitude: Float, buffers: Int) {
        for _ in 0..<buffers {
            router.process(buffer: makeBuffer(amplitude: amplitude))
        }
    }

    /// attach 直後のゲートは閉（セッションが state に同期して開く）。テストでは既定で開けておく。
    private func attachGate(
        _ router: AudioTapRouter, thresholds: ClientSpeechEndpointer.Thresholds = .init(),
        open: Bool = true
    ) -> AsyncStream<GatedMicEvent> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: GatedMicEvent.self, bufferingPolicy: .unbounded)
        router.attachGatedPCM16(
            format: sttFormat, thresholds: thresholds, continuation: continuation)
        if open { router.setSpeechGateOpen(true) }
        return stream
    }

    private func collect(_ stream: AsyncStream<GatedMicEvent>) async -> [GatedMicEvent] {
        var events: [GatedMicEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    /// 発話 1 回の基本形: 無音中は何も流れず、開始で「境界 + 遡り」、発話中は毎バッファ、
    /// 800ms の無音で終端境界が届く
    func testGateStreamsOnlySpeechSegmentWithLookback() async {
        let router = AudioTapRouter()
        let stream = attachGate(router)

        process(router, amplitude: 0.004, buffers: 30)  // 暗騒音（この間は何も流れない）
        process(router, amplitude: 0.1, buffers: 3)  // 発話開始（3 バッファで判定）
        process(router, amplitude: 0.1, buffers: 5)  // 発話中
        process(router, amplitude: 0.004, buffers: 19)  // 800ms 超の無音で終端
        process(router, amplitude: 0.004, buffers: 10)  // 終端後（何も流れない）
        router.detachRaw()

        let events = await collect(stream)
        XCTAssertEqual(events.first, .speechStarted)
        XCTAssertEqual(events.last, .speechStopped(forced: false))

        let audioChunks = events.dropFirst().dropLast()
        XCTAssertTrue(audioChunks.allSatisfy {
            if case .audio(let data) = $0 {
                // PCM16 mono: 1032 frames × 2 bytes
                return data.count == Int(framesPerBuffer) * 2
            }
            return false
        })
        // 遡り 12（≒ 0.5 秒。開始判定までの 3 バッファを含む）+ 発話 5 + 終端までの無音 19
        XCTAssertEqual(audioChunks.count, 12 + 5 + 19)
    }

    /// 遡りバッファは lookbackDuration ぶんに保たれる（無音が長くても膨らまない）
    func testLookbackIsCappedToConfiguredDuration() async {
        let router = AudioTapRouter()
        let stream = attachGate(router)

        process(router, amplitude: 0.004, buffers: 200)  // 長い無音
        process(router, amplitude: 0.1, buffers: 3)
        router.detachRaw()

        let events = await collect(stream)
        XCTAssertEqual(events.first, .speechStarted)
        // 0.5 秒 ÷ 43ms → 12 チャンク（200 バッファ全部は流れない）
        XCTAssertEqual(events.count - 1, 12)
    }

    /// STT 再接続時の仕切り直し: 進行中セグメントは破棄され、終端イベントも出ない
    func testResetSpeechGateDiscardsInProgressSegment() async {
        let router = AudioTapRouter()
        let stream = attachGate(router)

        process(router, amplitude: 0.004, buffers: 30)
        process(router, amplitude: 0.1, buffers: 3)  // 発話開始
        router.resetSpeechGate()
        process(router, amplitude: 0.004, buffers: 25)  // リセット後の無音（終端は出ない）
        router.detachRaw()

        let events = await collect(stream)
        XCTAssertEqual(events.first, .speechStarted)
        XCTAssertFalse(events.contains { event in
            if case .speechStopped = event { return true }
            return false
        })
    }

    // MARK: - ターンゲート（docs/plans/archive/turn-gated-voice-input.md）

    /// ゲートが閉じている間（AI のターン中）は、話しても何も流れない。開いたら通常どおり動く
    func testClosedGateSuppressesAllEvents() async {
        let router = AudioTapRouter()
        let stream = attachGate(router, open: false)

        process(router, amplitude: 0.004, buffers: 30)
        process(router, amplitude: 0.1, buffers: 10)  // AI のターン中に話しても無反応
        router.setSpeechGateOpen(true)
        process(router, amplitude: 0.1, buffers: 3)  // 自分のターンでは通常どおり検知
        router.detachRaw()

        let events = await collect(stream)
        XCTAssertEqual(events.first, .speechStarted)
        // 遡りはゲートを開いてからの 3 バッファぶんだけ（閉じている間は蓄積しない）
        XCTAssertEqual(events.count, 1 + 3)
    }

    /// 発話の途中でゲートが閉じたら（テキスト送信での割り込み等）セグメントを破棄し、
    /// 破棄が起きたことを戻り値で知らせる（呼び出し側がサーバ側バッファを clear する）
    func testClosingGateMidSpeechDiscardsSegment() async {
        let router = AudioTapRouter()
        let stream = attachGate(router)

        process(router, amplitude: 0.004, buffers: 30)
        process(router, amplitude: 0.1, buffers: 3)  // 発話開始
        XCTAssertTrue(router.setSpeechGateOpen(false))  // 発話中の破棄 = true
        process(router, amplitude: 0.004, buffers: 25)  // 終端イベントは出ない
        router.detachRaw()

        let events = await collect(stream)
        XCTAssertEqual(events.first, .speechStarted)
        XCTAssertFalse(events.contains { event in
            if case .speechStopped = event { return true }
            return false
        })
    }

    /// 発話していないときの閉鎖・同値の再設定は破棄なし（false）
    func testClosingGateWhileIdleReportsNoDiscard() {
        let router = AudioTapRouter()
        _ = attachGate(router)
        process(router, amplitude: 0.004, buffers: 10)
        XCTAssertFalse(router.setSpeechGateOpen(false))
        XCTAssertFalse(router.setSpeechGateOpen(false))  // 同値の再設定は no-op
        router.detachRaw()
    }

    /// maxSegmentDuration の強制終端は forced = true で届く（セッション側の info 表示用）
    func testForcedStopIsMarked() async {
        var thresholds = ClientSpeechEndpointer.Thresholds()
        thresholds.maxSegmentDuration = 0.5  // テスト用に短縮
        let router = AudioTapRouter()
        let stream = attachGate(router, thresholds: thresholds)

        process(router, amplitude: 0.004, buffers: 30)
        process(router, amplitude: 0.1, buffers: 15)  // 0.5 秒を超えて鳴り続ける
        router.detachRaw()

        let events = await collect(stream)
        XCTAssertTrue(events.contains(.speechStopped(forced: true)))
    }
}
