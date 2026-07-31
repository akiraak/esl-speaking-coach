import Accelerate
import AVFAudio
import Foundation

/// live（クライアント VAD）モードの送信ゲートが流すイベント。
/// 音声と発話境界を 1 本のストリームで運ぶことで、「append がすべて済んでから commit」の
/// 順序をストリームの順序そのままで保証する（docs/plans/archive/gpt-live-transcribe-adoption.md Phase 2）。
enum GatedMicEvent: Sendable, Equatable {
    /// 発話区間（+ 遡り）の PCM16 生バイト列
    case audio(Data)
    /// エンドポインタが発話開始を検知した（barge-in の起点。この直後に遡りぶんの audio が続く）
    case speechStarted
    /// エンドポインタが発話終端を検知した（受け手はここで commit を送る）。
    /// forced = true は maxSegmentDuration 到達の強制終端
    case speechStopped(forced: Bool)
}

/// マイクのタップから受け取ったバッファを、RMS レベルと（接続中なら）PCM16 の生バイト列へ配る。
/// process(buffer:) はオーディオスレッドから呼ばれるため NSLock で守る。
/// AVAudioConverter 等の非 Sendable な状態はこのクラス内に閉じ込める。
final class AudioTapRouter: @unchecked Sendable {
    let levels: AsyncStream<Float>

    private let levelContinuation: AsyncStream<Float>.Continuation
    private let lock = NSLock()
    private var rawContinuation: AsyncStream<Data>.Continuation?
    private var rawFormat: AVAudioFormat?
    private var rawConverter: AVAudioConverter?
    private var gatedContinuation: AsyncStream<GatedMicEvent>.Continuation?
    private var gatedFormat: AVAudioFormat?
    private var gatedConverter: AVAudioConverter?
    /// live モードのクライアント VAD（暗騒音は meter の推定を共有する）
    private var endpointer = ClientSpeechEndpointer()
    /// live の送信ゲートの開閉。自分が話すターン（listening）のときだけ開く
    /// （docs/plans/archive/turn-gated-voice-input.md。attach 直後は閉、セッションが state に同期させる）
    private var isSpeechGateOpen = false
    /// 発話開始判定時に prefix padding として送る直近チャンク（合計 ≒ lookbackDuration）
    private var lookbackChunks: [(data: Data, duration: TimeInterval)] = []
    private var lookbackTotal: TimeInterval = 0
    private var buffersReceived = 0
    /// 雑音セグメントの判定用。levels ストリームは .bufferingNewest(1) で取りこぼすため、
    /// 統計はここ（タップの呼び出しごと）で積む
    private var meter = SegmentLevelMeter()

    /// タップから受け取ったバッファ数の累計（マイクが生きているかの診断用）。
    var bufferCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffersReceived
    }

    init() {
        (levels, levelContinuation) = AsyncStream.makeStream(
            of: Float.self, bufferingPolicy: .bufferingNewest(1))
    }

    /// 指定フォーマット（PCM16 mono interleaved 前提）へ変換した生バイト列を流し始める。
    /// Realtime 系 API（音声チャンクをそのまま送る方式）向け。
    func attachRawPCM16(format: AVAudioFormat, continuation: AsyncStream<Data>.Continuation) {
        lock.lock()
        defer { lock.unlock() }
        rawContinuation = continuation
        rawFormat = format
        rawConverter = nil
    }

    /// live（サーバ VAD 非対応モデル）用の送信ゲート。PCM を常時流すのではなく、
    /// クライアント VAD が判定した発話区間 + 遡り（lookbackDuration）だけを流し、
    /// 発話境界イベントを同じストリームに挟む。attachRawPCM16 とは排他で使う。
    func attachGatedPCM16(
        format: AVAudioFormat,
        thresholds: ClientSpeechEndpointer.Thresholds,
        continuation: AsyncStream<GatedMicEvent>.Continuation
    ) {
        lock.lock()
        defer { lock.unlock() }
        gatedContinuation = continuation
        gatedFormat = format
        gatedConverter = nil
        endpointer = ClientSpeechEndpointer(thresholds: thresholds)
        isSpeechGateOpen = false
        lookbackChunks.removeAll()
        lookbackTotal = 0
    }

    /// live の送信ゲートを開閉する。閉じている間はエンドポインタ判定・遡り蓄積・append を
    /// 丸ごと止める（暗騒音の推定とレベル表示は動き続ける）。
    /// - Returns: 発話中セグメントを破棄したか。true なら呼び出し側でサーバ側の
    ///   append 済みバッファも clear すること（次セグメントの commit への混入防止）
    @discardableResult
    func setSpeechGateOpen(_ open: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard open != isSpeechGateOpen else { return false }
        isSpeechGateOpen = open
        let discardedActiveSegment = endpointer.isSpeaking
        endpointer.reset()
        lookbackChunks.removeAll()
        lookbackTotal = 0
        return discardedActiveSegment
    }

    /// raw / gated 両モードの配送を止める（マイク停止・セッション終了の共通処理）。
    func detachRaw() {
        lock.lock()
        defer { lock.unlock() }
        rawContinuation?.finish()
        rawContinuation = nil
        rawFormat = nil
        rawConverter = nil
        gatedContinuation?.finish()
        gatedContinuation = nil
        gatedFormat = nil
        gatedConverter = nil
        endpointer.reset()
        lookbackChunks.removeAll()
        lookbackTotal = 0
    }

    /// STT 再接続時の仕切り直し（live のみ意味を持つ）。送信中セグメントの append 済み音声は
    /// 旧接続側で失われているため、エンドポインタと遡りバッファを idle に戻して次の発話を待つ。
    func resetSpeechGate() {
        lock.lock()
        defer { lock.unlock() }
        endpointer.reset()
        lookbackChunks.removeAll()
        lookbackTotal = 0
    }

    /// AVAudioEngine のタップブロックとして渡す（オーディオスレッドから呼ばれる）。
    /// メソッド参照で渡すことで MainActor 隔離の推論を避ける（隔離クロージャだと実行時チェックで abort する）。
    func handleTap(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        process(buffer: buffer)
    }

    /// サーバ VAD の `speech_started` で呼ぶ。ここから `endLevelSegment()` までを 1 セグメントとして集計する。
    func beginLevelSegment() {
        lock.lock()
        defer { lock.unlock() }
        meter.beginSegment()
    }

    /// サーバ VAD の `speech_stopped` で呼ぶ。計測できていなければ nil。
    func endLevelSegment() -> SpeechSegmentLevels? {
        lock.lock()
        defer { lock.unlock() }
        return meter.endSegment()
    }

    /// 読み上げ中は暗騒音の更新を止める（VP 無効の端末でスピーカー出力が回り込むため）。
    func setNoiseFloorUpdateSuppressed(_ suppressed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        meter.isNoiseFloorUpdateSuppressed = suppressed
    }

    func process(buffer: AVAudioPCMBuffer) {
        let level = Self.rmsLevel(of: buffer)
        levelContinuation.yield(level)

        lock.lock()
        defer { lock.unlock() }
        meter.record(level)
        buffersReceived += 1
        if let continuation = rawContinuation, let format = rawFormat,
           let converted = convert(buffer, to: format, converter: &rawConverter),
           let data = Self.pcm16Data(from: converted) {
            continuation.yield(data)
        }
        if gatedContinuation != nil {
            processGated(buffer: buffer, level: level)
        }
    }

    /// 送信ゲート（ロック下で呼ぶ）: エンドポインタを駆動し、発話区間 + 遡りだけを流す。
    /// ゲートが閉じている間（AI のターン中）は何もしない。
    private func processGated(buffer: AVAudioPCMBuffer, level: Float) {
        guard isSpeechGateOpen else { return }
        guard let continuation = gatedContinuation, let format = gatedFormat else { return }
        // バッファ数ではなく実時間で判定する（HFP 等でサンプルレートが変わっても基準を保つ）
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        let data = convert(buffer, to: format, converter: &gatedConverter)
            .flatMap { Self.pcm16Data(from: $0) }
        let event = endpointer.record(
            level: level, duration: duration, noiseFloor: meter.currentNoiseFloor)

        switch event {
        case .speechStarted:
            // 現在のバッファも遡りに積んでから丸ごと流す。セグメント間で認識文脈が
            // 引き継がれないため、語頭の欠けは精度に直撃する
            if let data { appendLookback(data, duration: duration) }
            continuation.yield(.speechStarted)
            for chunk in lookbackChunks { continuation.yield(.audio(chunk.data)) }
            lookbackChunks.removeAll()
            lookbackTotal = 0
        case .speechStopped(let forced):
            // 終端判定のバッファまで送り切ってから境界を流す（受け手はここで commit する）
            if let data { continuation.yield(.audio(data)) }
            continuation.yield(.speechStopped(forced: forced))
        case nil:
            guard let data else { return }
            if endpointer.isSpeaking {
                continuation.yield(.audio(data))
            } else {
                appendLookback(data, duration: duration)
            }
        }
    }

    private func appendLookback(_ data: Data, duration: TimeInterval) {
        lookbackChunks.append((data, duration))
        lookbackTotal += duration
        while let first = lookbackChunks.first,
              lookbackTotal - first.duration >= endpointer.thresholds.lookbackDuration {
            lookbackTotal -= first.duration
            lookbackChunks.removeFirst()
        }
    }

    private func convert(
        _ buffer: AVAudioPCMBuffer, to format: AVAudioFormat, converter: inout AVAudioConverter?
    ) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return nil }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        // convert の入力ブロックは @Sendable 扱いのため、バッファの受け渡しを箱に閉じ込める
        // （ブロックは convert 呼び出し中に同期的に実行される）
        final class InputBox: @unchecked Sendable {
            var buffer: AVAudioPCMBuffer?
            init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        }
        let box = InputBox(buffer)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            guard let pending = box.buffer else {
                outStatus.pointee = .noDataNow
                return nil
            }
            box.buffer = nil
            outStatus.pointee = .haveData
            return pending
        }
        guard status != .error, conversionError == nil, output.frameLength > 0 else { return nil }
        return output
    }

    /// PCM16 mono interleaved バッファの生バイト列を取り出す。
    private static func pcm16Data(from buffer: AVAudioPCMBuffer) -> Data? {
        guard let channelData = buffer.int16ChannelData, buffer.frameLength > 0 else { return nil }
        return Data(
            bytes: channelData[0],
            count: Int(buffer.frameLength) * MemoryLayout<Int16>.size)
    }

    private static func rmsLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(channelData[0], 1, &rms, vDSP_Length(buffer.frameLength))
        return rms
    }
}

/// AVAudioEngine でマイクを常時タップする。バッファの配送は AudioTapRouter に委譲する。
/// メインスレッド（TurnBasedVoiceSession）から使う想定。@MainActor は付けない —
/// 付けるとタップクロージャが MainActor 隔離と推論され、オーディオスレッドからの呼び出しで
/// 実行時アイソレーション検査により abort する。
final class MicrophoneCapture {
    let router = AudioTapRouter()

    private let engine = AVAudioEngine()
    private var isRunning = false
    /// 直近の start 時点での入力フォーマット（診断表示用）。
    private(set) var inputFormatDescription = "-"

    /// - Parameter voiceProcessing: Voice Processing I/O（エコーキャンセル）を有効にするか。
    ///   TTS 再生中の barge-in 検知に必要。シミュレータ等で失敗しても続行する。
    func start(voiceProcessing: Bool) throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        // 前回の状態が残らないよう、要求値を常に明示的に設定する
        try? input.setVoiceProcessingEnabled(voiceProcessing)
        let format = input.outputFormat(forBus: 0)
        inputFormatDescription =
            "\(Int(format.sampleRate))Hz/\(format.channelCount)ch VP=\(input.isVoiceProcessingEnabled ? "on" : "off")"
        // 非隔離クラスのメソッド参照を渡す（クロージャリテラルだと周囲の隔離を継承してしまう）
        input.installTap(onBus: 0, bufferSize: 2048, format: format, block: router.handleTap)
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else {
            DiagnosticsLog.record("mic: stop（未起動のため何もしない）")
            return
        }
        // 入力エンジンの停止順序はクラッシュ調査の対象（docs/plans/end-session-crash.md H2）
        DiagnosticsLog.record("mic: stop 開始 buffers=\(router.bufferCount)")
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        DiagnosticsLog.record("mic: stop 完了")
    }
}
