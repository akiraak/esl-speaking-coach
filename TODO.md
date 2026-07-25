# TODO

## 実装（音声レイヤ: ターン制+Claude + Gemini TTS に決定済み・2026-07-25）

- [ ] モデル・パラメータの最終調整（TTS は Gemini Flash TTS 系で確定 — 既定 `gemini-3.1-flash-tts-preview`、必要なら 2.5 系と聞き比べ。voice の微調整（Chobi=Leda / Naruko=Aoede は決定済み）、VAD 無音判定 800ms の実使用チューニング、STT モデルの見直し。会話 LLM は `claude-sonnet-5` に決定済み）
- [ ] 会話履歴の永続化（SwiftData、端末内のみ。[conversation-design.md](docs/specs/conversation-design.md) の speaker 付き履歴モデルを保存対象にする）
- [ ] セッション後のフィードバック生成

## 実装

- [ ] 読み上げの再再生
- [ ] 管理画面の作成
  - 会話内容
  - AI利用料金
- [ ] アプリアイコンの作成
- [ ] アプリ表示名を変更