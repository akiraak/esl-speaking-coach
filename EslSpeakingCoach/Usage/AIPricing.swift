import Foundation

/// 単価表と推定額の計算（docs/specs/ai-cost-map.md の単価表をコード化。2026-07-25 時点の各社公表値）。
/// 単価は変動するため、推定額は**記録時に計算して保存**する（後から表を更新しても過去の記録は変わらない。
/// 生の usage も保存しているので必要なら再計算できる）。
enum AIPricing {
    /// claude-sonnet-5 の導入価格（$2/$10）はこの日まで。以降は $3/$15
    static let sonnet5IntroPriceEndsAfter = DateComponents(
        calendar: Calendar(identifier: .gregorian),
        timeZone: TimeZone(identifier: "America/Los_Angeles"),
        year: 2026, month: 8, day: 31, hour: 23, minute: 59, second: 59
    ).date!

    /// USD / 1M トークン。
    private struct ClaudeRates {
        let input: Double
        let output: Double
        /// キャッシュ読み込みは入力の 0.1 倍、書き込み（5 分 TTL）は 1.25 倍
        var cacheRead: Double { input * AIPricing.cacheReadMultiplier }
        var cacheWrite: Double { input * AIPricing.cacheWriteMultiplier }
    }

    private static let cacheReadMultiplier = 0.1
    private static let cacheWriteMultiplier = 1.25

    /// 1 イベントの推定額（USD）。at は記録時刻（sonnet-5 導入価格の判定に使う）。
    static func estimatedCostUSD(for event: AIUsageEvent, at date: Date = Date()) -> Double {
        switch event.provider {
        case .anthropic:
            return claudeCost(event: event, at: date)
        case .openai:
            switch event.kind {
            case .speechToText:
                return openAITranscribeCost(event: event)
            default:
                // gpt-4o-mini-tts（聞き比べ用）: 分単価の概算のみ
                return (event.audioSeconds ?? 0) * openAIMiniTTSUSDPerMinute / 60
            }
        case .gemini:
            return geminiTTSCost(event: event)
        case .alibaba:
            switch event.kind {
            case .speechToText:
                return qwenASRCost(event: event)
            default:
                return qwenTTSCost(event: event)
            }
        }
    }

    // MARK: - Claude（会話ターン / トピック生成 / フィードバック生成 / 記憶更新 / 翻訳）

    private static func claudeCost(event: AIUsageEvent, at date: Date) -> Double {
        let rates = claudeRates(model: event.model, at: date)
        var cost = 0.0
        cost += perMillion(event.inputTokens, rate: rates.input)
        cost += perMillion(event.outputTokens, rate: rates.output)
        cost += perMillion(event.cacheReadTokens, rate: rates.cacheRead)
        cost += perMillion(event.cacheWriteTokens, rate: rates.cacheWrite)
        return cost
    }

    private static func claudeRates(model: String, at date: Date) -> ClaudeRates {
        // claude-opus-5（〜2026-07-31 のフィードバック生成）。過去記録の生 usage 再計算用に残す
        if model.contains("opus") {
            return ClaudeRates(input: 5, output: 25)
        }
        // claude-haiku-4-5（会話の翻訳）
        if model.contains("haiku") {
            return ClaudeRates(input: 1, output: 5)
        }
        // claude-sonnet-5（既定）。〜2026-08-31 は導入価格
        if date <= sonnet5IntroPriceEndsAfter {
            return ClaudeRates(input: 2, output: 10)
        }
        return ClaudeRates(input: 3, output: 15)
    }

    // MARK: - OpenAI STT（gpt-4o-transcribe / gpt-live-transcribe）

    /// gpt-live-transcribe（2026-07-31 採用・既定）: セッション音声 $0.017 / 分の分数課金
    /// （docs/plans/archive/gpt-live-transcribe-adoption.md。usage は duration 型・秒単位
    /// 切り上げで届く。秒数が取れないときは 0 になるが生 usage から再計算できる）。
    /// gpt-4o-transcribe（-stt-model で戻せる旧既定）: 音声入力 $6 / 1M、テキスト入力
    /// $2.50 / 1M、出力 $10 / 1M。トークンが取れないときは音声 1 分 ≈ $0.006 で概算する。
    private static let liveTranscribeUSDPerMinute = 0.017
    private static let transcribe4oAudioInputRate = 6.0
    private static let transcribe4oTextInputRate = 2.5
    private static let transcribe4oOutputRate = 10.0
    private static let transcribe4oFallbackUSDPerMinute = 0.006
    private static let openAIMiniTTSUSDPerMinute = 0.015

    private static func openAITranscribeCost(event: AIUsageEvent) -> Double {
        if event.model.hasPrefix("gpt-live-transcribe") {
            return (event.audioSeconds ?? 0) * liveTranscribeUSDPerMinute / 60
        }
        if event.audioInputTokens != nil || event.inputTokens != nil || event.outputTokens != nil {
            var cost = 0.0
            cost += perMillion(event.audioInputTokens, rate: transcribe4oAudioInputRate)
            cost += perMillion(event.inputTokens, rate: transcribe4oTextInputRate)
            cost += perMillion(event.outputTokens, rate: transcribe4oOutputRate)
            return cost
        }
        return (event.audioSeconds ?? 0) * transcribe4oFallbackUSDPerMinute / 60
    }

    // MARK: - Gemini Flash TTS（読み上げ）

    /// gemini-3.1-flash-tts-preview: テキスト入力 $1 / 1M、音声出力 $20 / 1M（25 トークン/秒）。
    /// トークンが取れないときは音声秒数 × 25 トークンで概算する。
    private static let geminiTTSTextInputRate = 1.0
    private static let geminiTTSAudioOutputRate = 20.0
    private static let geminiTTSTokensPerSecond = 25.0

    private static func geminiTTSCost(event: AIUsageEvent) -> Double {
        var cost = perMillion(event.inputTokens, rate: geminiTTSTextInputRate)
        if let outputTokens = event.outputTokens {
            cost += perMillion(outputTokens, rate: geminiTTSAudioOutputRate)
        } else if let seconds = event.audioSeconds {
            cost += seconds * geminiTTSTokensPerSecond / 1_000_000 * geminiTTSAudioOutputRate
        }
        return cost
    }

    private static func perMillion(_ tokens: Int?, rate: Double) -> Double {
        Double(tokens ?? 0) / 1_000_000 * rate
    }

    // MARK: - Alibaba Qwen 音声モデル（TTS は 2026-08-01 採用・既定。ASR は切替用。
    // docs/plans/archive/alibaba-voice-models.md）

    /// qwen3-asr-flash-realtime: 音声 $0.000090 / 秒（2026-07-31 に国際版公式料金ページで確認。
    /// usage は duration 型・秒単位で届く）。
    private static let qwenASRUSDPerSecond = 0.000090
    /// qwen3-tts-flash-realtime: $0.13 / 1 万文字。課金単位の文字数は response.done の
    /// usage.characters で届き、QwenTTSClient が TTSUsage.inputTokens に入れて運ぶ。
    /// 既定の instruct 変種（qwen3-tts-instruct-flash-realtime）の単価は公式ページに記載が無く
    /// 未確認のため、暫定で base と同額として計上する（コンソール / 初回請求で確認して確定する）。
    private static let qwenTTSUSDPer10kCharacters = 0.13
    /// 文字数が取れないときの概算: 生成音声 1 分 ≈ $0.0098（実測の話速からの換算）。
    private static let qwenTTSFallbackUSDPerMinute = 0.0098

    private static func qwenASRCost(event: AIUsageEvent) -> Double {
        (event.audioSeconds ?? 0) * qwenASRUSDPerSecond
    }

    private static func qwenTTSCost(event: AIUsageEvent) -> Double {
        // inputTokens には課金文字数（usage.characters）が入っている
        if let characters = event.inputTokens {
            return Double(characters) / 10_000 * qwenTTSUSDPer10kCharacters
        }
        return (event.audioSeconds ?? 0) * qwenTTSFallbackUSDPerMinute / 60
    }

    // MARK: - 種別ごとの現在単価（管理画面「料金」タブの種別内訳に表示）

    /// 種別で現在使っている既定モデルと単価。price / note は表示用に整形済み。
    struct KindRate {
        let model: String
        let price: String
        let note: String?
    }

    /// 種別 → **いま選ばれているモデル**と単価（管理画面「モデル」の選択に追従する）。
    /// 推定額の計算に使っている定数から組み立てるので、単価改定でこのファイルを更新すれば
    /// 表示も追従する。at は sonnet-5 導入価格の判定に使う。
    static func currentRate(
        for kind: AIUsageEvent.Kind,
        selection: ModelSelectionSnapshot,
        at date: Date = Date()
    ) -> KindRate {
        switch kind {
        case .conversationTurn: return claudeRate(.conversationTurn, selection: selection, at: date)
        case .topicSuggestion: return claudeRate(.topicSuggestion, selection: selection, at: date)
        case .sessionFeedback: return claudeRate(.sessionFeedback, selection: selection, at: date)
        case .memoryUpdate: return claudeRate(.memoryUpdate, selection: selection, at: date)
        case .translation: return claudeRate(.translation, selection: selection, at: date)
        case .speechToText:
            let model = selection.sttModel
            return KindRate(
                model: model.rawValue, price: priceDescription(for: model), note: note(for: model))
        case .textToSpeech:
            let provider = selection.ttsProvider
            return KindRate(
                model: provider.modelDescription,
                price: priceDescription(for: provider),
                note: note(for: provider))
        }
    }

    /// Claude 経路の単価行。導入価格の期間中は「以降はいくらになるか」を補足に出す。
    private static func claudeRate(
        _ route: ClaudeRoute, selection: ModelSelectionSnapshot, at date: Date
    ) -> KindRate {
        let model = selection.model(for: route)
        let current = claudeRates(model: model.rawValue, at: date)
        let regular = claudeRates(
            model: model.rawValue, at: sonnet5IntroPriceEndsAfter.addingTimeInterval(1))
        let isIntroPrice = current.input != regular.input || current.output != regular.output
        return KindRate(
            model: model.rawValue,
            price: tokenPrice(input: current.input, output: current.output),
            note: isIntroPrice
                ? "〜2026-08-31 は導入価格。以降は \(tokenPrice(input: regular.input, output: regular.output))"
                : nil)
    }

    /// 単価表の但し書き（課金の効き方・暫定計上）。
    private static func note(for model: STTModel) -> String? {
        switch model {
        case .live: return "秒単位切り上げ"
        case .transcribe4o: return "実際は音声入力トークン課金（\(usd(transcribe4oAudioInputRate)) / 1M）"
        case .qwenASR: return nil
        }
    }

    private static func note(for provider: TTSProvider) -> String? {
        switch provider {
        case .gemini:
            return "音声出力トークン課金（\(usd(geminiTTSAudioOutputRate)) / 1M・"
                + "\(Int(geminiTTSTokensPerSecond)) トークン/秒）"
        case .qwen:
            return "instruct の単価は未公表のため base の確認値を暫定計上"
        case .openAI:
            return "参考値・要再確認"
        }
    }

    /// 表示用の単価（1M トークン）。**単価表はこのファイルが単一の正**なので、画面はここを呼ぶ。
    static func tokenPriceDescription(for model: ClaudeModel, at date: Date = Date()) -> String {
        let rates = claudeRates(model: model.rawValue, at: date)
        return tokenPrice(input: rates.input, output: rates.output)
    }

    /// 表示用の単価（STT。管理画面のモデル選択）。
    static func priceDescription(for model: STTModel) -> String {
        switch model {
        case .live:
            return "音声 \(usd(liveTranscribeUSDPerMinute)) / 分（発話セグメント分のみ）"
        case .transcribe4o:
            return "音声 約 \(usd(transcribe4oFallbackUSDPerMinute)) / 分"
        case .qwenASR:
            return "音声 \(usd(qwenASRUSDPerSecond * 60)) / 分"
        }
    }

    /// 表示用の単価（TTS。管理画面のプロバイダ選択）。
    static func priceDescription(for provider: TTSProvider) -> String {
        switch provider {
        case .gemini:
            return "生成音声 1 分 ≈ \(usd(geminiTTSUSDPerMinute))"
        case .qwen:
            return "\(usd(qwenTTSUSDPer10kCharacters)) / 1 万文字"
                + "（生成音声 1 分 ≈ \(usd(qwenTTSFallbackUSDPerMinute))）"
        case .openAI:
            return "音声 1 分 ≈ \(usd(openAIMiniTTSUSDPerMinute))"
        }
    }

    /// 生成音声 1 分あたりの Gemini TTS 代（音声出力トークンの単価から算出）。
    private static var geminiTTSUSDPerMinute: Double {
        geminiTTSTokensPerSecond * 60 / 1_000_000 * geminiTTSAudioOutputRate
    }

    private static func tokenPrice(input: Double, output: Double) -> String {
        "入力 \(usd(input)) / 出力 \(usd(output))（1M トークン）"
    }

    private static func usd(_ value: Double) -> String {
        "$" + trimmed(value)
    }

    /// 末尾の余分な 0 を落とす（2 → "2", 2.5 → "2.5", 0.017 → "0.017"）。
    private static func trimmed(_ value: Double) -> String {
        String(format: "%g", value)
    }
}
