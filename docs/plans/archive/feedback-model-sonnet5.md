# フィードバック生成のモデルを claude-opus-5 → claude-sonnet-5 に変更する

2026-07-31 作成。

## 目的・背景

アプリ内で `claude-opus-5` を使っているのはセッション後フィードバック生成
（`Claude/SessionFeedbackClient.swift`）だけ。単発呼び出しとしてはアプリ内で最も高額
（opus 単価 × 会話全文入力 + 数千トークン出力）なので、`claude-sonnet-5` に切り替えてコストを下げる
（概算例のフィードバック 1 回 $0.10 → $0.06（通常価格時））。effort high / max_tokens 16000 /
ストリーミング + structured outputs の呼び方は変えない。

## 対応方針

1. `SessionFeedbackClient` にモデル定数を 1 箇所化（`static let model`）し、リクエストボディと
   usage 記録の両方で参照する。値を `claude-sonnet-5` に変更
2. `AIPricing.rateTable()`: sonnet-5 行の用途に「フィードバック」を追加し、使わなくなった opus-5 の行を削除
   - 料金計算の opus 分岐（`claudeRates`）は**残す**（過去に記録した opus イベントの生 usage 再計算用）
3. ドキュメント更新: `CLAUDE.md`（技術スタック・API 規約のモデル指定）、`README.md`、
   `docs/specs/conversation-design.md`、`docs/specs/session-feedback.md`、
   `docs/specs/ai-cost-map.md`（課金マップ #5・単価表（opus は参考へ）・詳細 5・概算例の再計算）

## 影響範囲

- `EslSpeakingCoach/Claude/SessionFeedbackClient.swift`
- `EslSpeakingCoach/Usage/AIPricing.swift`（表示のみ。計算は不変）
- `EslSpeakingCoachTests/SessionFeedbackClientTests.swift` / `AIPricingTests.swift`
- 上記ドキュメント 5 件
- フィードバックの品質が opus 比で落ちる可能性は許容（気になったら戻す。定数 1 箇所で戻せる）

## テスト方針

- `SessionFeedbackClientTests` のモデル検証を sonnet-5 に更新
- `AIPricingTests` の単価表テストから opus 行を除去（opus の計算テストは過去記録用として残す）
- 全テスト + シミュレータビルドが通ること
