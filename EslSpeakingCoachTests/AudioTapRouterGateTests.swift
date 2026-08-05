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
        mode: SpeechGateMode = .listening
    ) -> AsyncStream<GatedMicEvent> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: GatedMicEvent.self, bufferingPolicy: .unbounded)
        router.attachGatedPCM16(
            format: sttFormat, thresholds: thresholds, continuation: continuation)
        router.setSpeechGateMode(mode)
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

    /// ゲートが閉じている間は、話しても何も流れない。開いたら通常どおり動く
    func testClosedGateSuppressesAllEvents() async {
        let router = AudioTapRouter()
        let stream = attachGate(router, mode: .closed)

        process(router, amplitude: 0.004, buffers: 30)
        process(router, amplitude: 0.1, buffers: 10)  // 閉じている間は話しても無反応
        router.setSpeechGateMode(.listening)
        process(router, amplitude: 0.1, buffers: 3)  // 開いたら通常どおり検知
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
        XCTAssertTrue(router.setSpeechGateMode(.closed))  // 発話中の破棄 = true
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
        XCTAssertFalse(router.setSpeechGateMode(.closed))
        XCTAssertFalse(router.setSpeechGateMode(.closed))  // 同値の再設定は no-op
        router.detachRaw()
    }

    // MARK: - AI ターン中の非対称しきい値（docs/plans/always-on-voice-input.md Phase 3）

    /// 2026-08-04 にエコーを実測したときの listening 設定（プリセット「生活音のある部屋」相当）。
    /// 派生の効き目はこの実値との対比で見ないと意味がないので、テストでも同じ値を使う
    private var measuredThresholds: ClientSpeechEndpointer.Thresholds {
        var thresholds = ClientSpeechEndpointer.Thresholds()
        thresholds.minimumPeak = 0.016
        thresholds.snrRatio = 4.0
        thresholds.unconditionalPeak = 0.06
        thresholds.minimumSpeechDuration = 0.20
        return thresholds
    }

    /// 2026-08-04 の実測（本体スピーカー・ターン 3）そのままの再現:
    /// エコー残留 0.020 は **listening のしきい値では発話開始になってしまう**が、
    /// AI ターンの派生（0.016 × 1.5 = 0.024）では発火しない。本人の声はどちらでも通る。
    ///
    /// 読み上げ中は暗騒音の更新が止まる（＝ `snrRatio` が効かない）ので、
    /// セッションと同じく `setNoiseFloorUpdateSuppressed(true)` を張ってから流す。
    func testAssistantTurnModeIgnoresEchoThatWouldFireDuringListening() async {
        func run(mode: SpeechGateMode) async -> [GatedMicEvent] {
            let router = AudioTapRouter()
            let stream = attachGate(router, thresholds: measuredThresholds, mode: mode)
            process(router, amplitude: 0.004, buffers: 30)  // 自分のターンの静けさ（floor 0.004）
            router.setNoiseFloorUpdateSuppressed(true)  // 読み上げ開始（フロアの更新は止まる）
            process(router, amplitude: 0.020, buffers: 20)  // エコー残留 0.86 秒ぶん
            router.detachRaw()
            return await collect(stream)
        }

        let duringListening = await run(mode: .listening)
        XCTAssertEqual(duringListening.first, .speechStarted,
                       "現行の listening しきい値のままゲートを開けると誤発火する")

        let duringAssistantTurn = await run(mode: .assistantTurn)
        XCTAssertTrue(duringAssistantTurn.isEmpty, "AI ターンの派生ではエコーで発火しない")
    }

    /// AI の読み上げ中でも本人の声は通る（厳しくしたのは誤発火を弾くぶんだけ）
    func testAssistantTurnModePassesRealSpeech() async {
        let router = AudioTapRouter()
        let stream = attachGate(router, thresholds: measuredThresholds, mode: .assistantTurn)

        process(router, amplitude: 0.004, buffers: 30)
        router.setNoiseFloorUpdateSuppressed(true)
        process(router, amplitude: 0.020, buffers: 20)  // エコー（発火しない）
        process(router, amplitude: 0.1, buffers: 7)  // 本人の声。0.30 秒 = 7 バッファで発話開始
        router.detachRaw()

        let events = await collect(stream)
        XCTAssertEqual(events.first, .speechStarted)
        // 発話開始は 1 回だけ（エコーでは発火していない）+ 遡り 12（0.5 秒）
        XCTAssertEqual(events.count, 1 + 12)
    }

    /// 発話開始の継続時間も厳しくなる: listening なら発火する 3 バッファ（0.129 秒）では
    /// AI ターン中は発火しない
    func testAssistantTurnModeRequiresLongerSpeechRun() async {
        let router = AudioTapRouter()
        let stream = attachGate(router, mode: .assistantTurn)

        process(router, amplitude: 0.004, buffers: 30)
        process(router, amplitude: 0.1, buffers: 3)  // listening なら発話開始になる長さ
        router.detachRaw()

        let events = await collect(stream)
        XCTAssertTrue(events.isEmpty, "0.30 秒に満たない発話は AI ターン中は発火しない")
    }

    /// 開いたまま listening ⇄ assistantTurn を移っても、進行中のセグメントは切らない。
    /// 読み上げ中に話し始めた発話が、読み上げ終了の瞬間に途切れないための保証
    func testSwitchingBetweenOpenModesKeepsActiveSegment() async {
        let router = AudioTapRouter()
        let stream = attachGate(router, mode: .assistantTurn)

        process(router, amplitude: 0.004, buffers: 30)
        process(router, amplitude: 0.1, buffers: 7)  // AI の読み上げ中に話し始めた
        XCTAssertFalse(router.setSpeechGateMode(.listening), "開 ⇄ 開では破棄しない")
        process(router, amplitude: 0.1, buffers: 5)  // 読み上げ終了後も同じ発話が続く
        process(router, amplitude: 0.004, buffers: 19)  // 無音で終端
        router.detachRaw()

        let events = await collect(stream)
        XCTAssertEqual(events.first, .speechStarted)
        XCTAssertEqual(events.last, .speechStopped(forced: false))
        // 発話開始は 1 回だけ（モード切替で仕切り直されていない）
        XCTAssertEqual(events.filter { $0 == .speechStarted }.count, 1)
    }

    /// AI ターン用の派生（純関数）: 上げるのは発話**開始**の条件だけで、終端・遡りは共通
    func testAssistantTurnDerivedThresholds() {
        var thresholds = ClientSpeechEndpointer.Thresholds()
        thresholds.minimumPeak = 0.016
        thresholds.unconditionalPeak = 0.06
        thresholds.minimumSpeechDuration = 0.20
        thresholds.silenceDuration = 1.2
        let derived = thresholds.assistantTurnDerived

        XCTAssertEqual(derived.minimumPeak, 0.016 * 1.5, accuracy: 0.0001)
        XCTAssertEqual(derived.minimumSpeechDuration, 0.30, accuracy: 0.0001)
        XCTAssertEqual(derived.silenceDuration, thresholds.silenceDuration)
        XCTAssertEqual(derived.snrRatio, thresholds.snrRatio)
        XCTAssertEqual(derived.lookbackDuration, thresholds.lookbackDuration)
        XCTAssertEqual(derived.maxSegmentDuration, thresholds.maxSegmentDuration)
    }

    /// 持ち上げた下限が上限（unconditionalPeak）を超えるときは上限も一緒に押し上げる。
    /// でないと `min(max(floor × snr, minimumPeak), unconditionalPeak)` で削られて厳しくならない
    func testAssistantTurnDerivedRaisesUnconditionalPeakWhenNeeded() {
        var thresholds = ClientSpeechEndpointer.Thresholds()
        thresholds.minimumPeak = 0.05
        thresholds.unconditionalPeak = 0.06
        let derived = thresholds.assistantTurnDerived

        XCTAssertEqual(derived.minimumPeak, 0.075, accuracy: 0.0001)
        XCTAssertEqual(derived.unconditionalPeak, 0.075, accuracy: 0.0001)
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
