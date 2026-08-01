# 料金画面の修正: 種別内訳へのモデル・単価表示と今月ベース化

## 目的・背景

管理画面「料金」タブは現在、種別内訳（累計）と単価表（現在適用中の全モデル）を別々のセクションで出している。

- 単価表は切替用・聞き比べ用の旧モデルまで並び、普段見たい情報（いま使っているモデルと単価）がノイズに埋もれる
- 種別内訳が累計のため、「今月いくら・どの種別が支配的か」が読み取れない

そこで次の 2 点を行う（TODO.md「料金画面の修正」）。

1. 種別内訳の各行に、その種別で**現在使っているモデルと単価**を表示する。代わりに単価表セクションを削除する
2. 種別内訳を**今月分**の金額にし、今月全体料金に対する割合を % で併記する

## 対応方針

### AIPricing（単価表 → 種別ごとの現在単価）

- `RateRow` / `rateTable()` を削除し、`KindRate`（`model` / `price` / `note?`）と
  `currentRate(for kind: AIUsageEvent.Kind, at date: Date = Date()) -> KindRate` を追加する
- 種別 → 現在の既定モデルの対応（切替用の旧経路は表示しない）:
  - 会話ターン / トピック生成 / フィードバック生成 / 記憶更新 → `claude-sonnet-5`（導入価格の note 付き。`at` で判定）
  - 会話の翻訳 → `claude-haiku-4-5`
  - 音声認識 (STT) → `gpt-live-transcribe`（$0.017 / 分）
  - 読み上げ (TTS) → `qwen3-tts-instruct-flash-realtime`（$0.13 / 1 万文字。暫定計上の note 付き）
- 単価文字列は既存の定数・整形ヘルパ（`tokenPrice` / `usd`）から組み立て、単価改定でコードを直せば表示が追従する構造を維持する

### UsageStore（種別内訳の今月ベース化）

- `kindTotals()` を `kindTotals(monthOf now: Date = Date())` に変更し、今月分（`monthStart <= timestamp`）だけを合算する
- **追補（実装後の指摘対応）**: 今月ベース化すると月初などに利用のない種別（翻訳・STT 等）が丸ごと消えるため、
  `Kind.allCases` 全 7 種別を $0 で常時返す（金額降順・同額は課金経路の定義順）。ビューの「空なら非表示」条件も撤去

### UsageDashboardView

- セクション名を「種別内訳（今月）」にし、各行を「種別ラベル + モデル・単価のキャプション（+note）／右側に金額と今月合計比 %」のレイアウトへ変更する
- % は `totals.thisMonthUSD` を分母に計算する（0 除算は 0% 扱い）
- 単価表セクションを削除し、「単価は現在適用中。推定額は記録時の単価で計算・保存」の注意書きを種別内訳の footer に移す

## 影響範囲

- `EslSpeakingCoach/Usage/AIPricing.swift`
- `EslSpeakingCoach/Persistence/UsageStore.swift`
- `EslSpeakingCoach/Admin/UsageDashboardView.swift`
- `EslSpeakingCoachTests/AIPricingTests.swift`（rateTable のテスト 2 件を currentRate のテストに置換）
- `EslSpeakingCoachTests/UsageStoreTests.swift`（kindTotals の月フィルタを検証）
- `docs/specs/ai-cost-map.md`（`rateTable()` への言及を更新）

## テスト方針

- `currentRate(for:at:)`: sonnet-5 の導入価格期間内 / 終了後の単価と note の有無、全種別 → モデルの対応
- `kindTotals(monthOf:)`: 先月以前の記録が合算から除外されること、金額降順の維持
- `xcodebuild` でビルドとユニットテストを通す。表示レイアウトはシミュレータで目視確認
