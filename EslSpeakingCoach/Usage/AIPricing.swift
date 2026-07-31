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
        var cacheRead: Double { input * 0.1 }
        var cacheWrite: Double { input * 1.25 }
    }

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
                // gpt-4o-mini-tts（聞き比べ用）: 音声 1 分 ≈ $0.015 の概算のみ
                return (event.audioSeconds ?? 0) * 0.015 / 60
            }
        case .gemini:
            return geminiTTSCost(event: event)
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
    private static func openAITranscribeCost(event: AIUsageEvent) -> Double {
        if event.model.hasPrefix("gpt-live-transcribe") {
            return (event.audioSeconds ?? 0) * 0.017 / 60
        }
        if event.audioInputTokens != nil || event.inputTokens != nil || event.outputTokens != nil {
            var cost = 0.0
            cost += perMillion(event.audioInputTokens, rate: 6)
            cost += perMillion(event.inputTokens, rate: 2.5)
            cost += perMillion(event.outputTokens, rate: 10)
            return cost
        }
        return (event.audioSeconds ?? 0) * 0.006 / 60
    }

    // MARK: - Gemini Flash TTS（読み上げ）

    /// gemini-3.1-flash-tts-preview: テキスト入力 $1 / 1M、音声出力 $20 / 1M（25 トークン/秒）。
    /// トークンが取れないときは音声秒数 × 25 トークンで概算する。
    private static func geminiTTSCost(event: AIUsageEvent) -> Double {
        var cost = perMillion(event.inputTokens, rate: 1)
        if let outputTokens = event.outputTokens {
            cost += perMillion(outputTokens, rate: 20)
        } else if let seconds = event.audioSeconds {
            cost += seconds * 25 / 1_000_000 * 20
        }
        return cost
    }

    private static func perMillion(_ tokens: Int?, rate: Double) -> Double {
        Double(tokens ?? 0) / 1_000_000 * rate
    }
}
