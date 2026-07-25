# AI 利用料金マップの spec 作成

## 目的・背景

- TODO「現在の仕様で AI の料金がかかる箇所を分かりやすく spec にまとめる」への対応
- 本アプリはバックエンドなしで 3 プロバイダ（Anthropic / OpenAI / Google Gemini）の API を直叩きするため、どの操作がどの API 課金を発生させるかが分散していて見通しにくい
- 将来の「管理画面（AI 利用料金）」タスクの土台にもなる

## 対応方針

1. コードと既存 spec（`conversation-design.md`）から AI API の呼び出し箇所を全て洗い出す
   - 実装済み: STT（gpt-4o-transcribe / WebSocket 常時接続）、会話 LLM（Claude ストリーミング）、TTS（Gemini Flash TTS 文単位 / OpenAI TTS 切替）、検証用の 案 B（OpenAI Realtime）・案 C（Gemini Live）
   - 設計済み・未実装: トピック生成（sonnet / structured outputs）、フィードバック生成（opus / effort high）
2. 「操作 → 発生する API 呼び出し → 課金単位 → コスト特性」の対応表として `docs/specs/ai-cost-map.md` にまとめる
3. 単価は claude-api スキル + Web 検索で 2026-07-25 時点のものを確認して記載し、変動前提の注意書きを付ける
4. コスト構造上の注意点（履歴再送で入力トークンが逓増、STT の常時ストリーミング、barge-in で破棄される TTS、prompt cache の効き方）を明記する

## 影響範囲

- 新規: `docs/specs/ai-cost-map.md`
- 更新: `TODO.md`（リンク追記 → 完了時に DONE.md へ）
- コード変更なし

## テスト方針

- コード変更がないためビルド確認は不要
- spec 内の呼び出し箇所の記述が実装（ファイル名・モデル名・呼び出しタイミング）と一致していることを確認する
