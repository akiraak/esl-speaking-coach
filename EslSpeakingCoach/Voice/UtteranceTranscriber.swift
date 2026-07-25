import AVFAudio
import Foundation
import Speech

enum TranscriberError: Error, LocalizedError {
    case localeNotSupported(Locale)
    case audioFormatUnavailable

    var errorDescription: String? {
        switch self {
        case .localeNotSupported(let locale):
            return "SpeechTranscriber がロケール \(locale.identifier) に対応していません"
        case .audioFormatUnavailable:
            return "SpeechAnalyzer の対応音声フォーマットを取得できませんでした"
        }
    }
}

/// 1 発話ぶんの SpeechAnalyzer + SpeechTranscriber ラッパ。
/// ターンごとに使い捨て、発話終端の確定時に finishAndCollect() で全文を取り出す。
@MainActor
final class UtteranceTranscriber {
    /// マイクタップから変換済みバッファを流し込む先。
    let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    /// analyzer が要求する音声フォーマット（タップ側でこれに変換する）。
    let analyzerFormat: AVAudioFormat

    /// finalized + volatile の現在形が更新されるたびに呼ばれる。
    var onUpdate: ((String) -> Void)?

    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private var recognitionTask: Task<Void, Never>?
    private var finalizedText = ""
    private var volatileText = ""

    /// 認識モデルの確認とダウンロードを行い、実際に使うロケールを返す。
    /// ロケールを reserve していないと "not subscribed to transcription.en" で失敗するため、
    /// reserve → assetInstallationRequest の順で行う。
    /// ダウンロードが走る場合は onProgress に進捗（0.0〜1.0）を約 1 秒間隔で通知する。
    static func ensureModelInstalled(
        locale: Locale,
        onProgress: (@MainActor @Sendable (Double) -> Void)? = nil
    ) async throws -> Locale {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriberError.localeNotSupported(locale)
        }
        let reserved = await AssetInventory.reservedLocales
        if !reserved.contains(supported) {
            try await AssetInventory.reserve(locale: supported)
        }
        let probe = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [])

        let installed = await SpeechTranscriber.installedLocales
        let status = await AssetInventory.status(forModules: [probe])
        NSLog("[VoiceSpike] resolved=%@ status=%@ installed=%@ reserved=%@",
              supported.identifier, String(describing: status),
              installed.map(\.identifier).joined(separator: ","),
              (await AssetInventory.reservedLocales).map(\.identifier).joined(separator: ","))

        // すでにインストール済みならダウンロード要求を出さない
        // （シミュレータでは assetInstallationRequest が "not subscribed" で失敗することがある）
        if status == .installed || installed.contains(where: {
            $0.identifier(.bcp47) == supported.identifier(.bcp47)
        }) {
            return supported
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            let progress = request.progress
            let poller: Task<Void, Never>? = onProgress.map { report in
                Task { @MainActor in
                    while !Task.isCancelled {
                        report(progress.fractionCompleted)
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
            }
            defer { poller?.cancel() }
            try await request.downloadAndInstall()
        }
        return supported
    }

    init(locale: Locale) async throws {
        transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [])
        analyzer = SpeechAnalyzer(modules: [transcriber])

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        else {
            throw TranscriberError.audioFormatUnavailable
        }
        analyzerFormat = format

        let (inputSequence, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        inputContinuation = continuation

        try await analyzer.start(inputSequence: inputSequence)

        recognitionTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in self.transcriber.results {
                    self.apply(text: String(result.text.characters), isFinal: result.isFinal)
                }
            } catch {
                // キャンセルや finish 由来の終了はここに来る。発話確定側でハンドリング済み
            }
        }
    }

    var currentText: String {
        Self.joined(finalizedText, volatileText)
    }

    /// 入力を締めて最終テキストを取り出す。発話終端の確定時に一度だけ呼ぶ。
    func finishAndCollect() async throws -> String {
        inputContinuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        _ = await recognitionTask?.value
        let text = finalizedText.isEmpty ? volatileText : Self.joined(finalizedText, volatileText)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 途中破棄（セッション停止・barge-in 後の作り直し等）。
    func cancel() {
        inputContinuation.finish()
        recognitionTask?.cancel()
        let analyzer = analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }

    private func apply(text: String, isFinal: Bool) {
        if isFinal {
            finalizedText = Self.joined(finalizedText, text)
            volatileText = ""
        } else {
            volatileText = text
        }
        onUpdate?(currentText)
    }

    private static func joined(_ lhs: String, _ rhs: String) -> String {
        if lhs.isEmpty { return rhs }
        if rhs.isEmpty { return lhs }
        if lhs.hasSuffix(" ") || rhs.hasPrefix(" ") { return lhs + rhs }
        return lhs + " " + rhs
    }
}
