# TODO

## 実装（音声レイヤ: ターン制+Claude + Gemini TTS に決定済み・2026-07-25）

- [ ] 音声入出力の本実装（スパイクの `TurnBasedVoiceSession`（案 A2）を製品品質に引き上げる: STT 接続断からの自動再接続、バックグラウンド遷移・オーディオ割り込み（電話等）対応、エラー時の復帰導線）
- [ ] モデル・パラメータの最終調整（TTS は Gemini Flash TTS 系で確定 — 既定 `gemini-3.1-flash-tts-preview`、必要なら 2.5 系と聞き比べ。voice 選定、VAD 無音判定 800ms の実使用チューニング、STT / LLM モデルの見直し）
- [ ] 検証用コードの整理（不採用の案 B: OpenAI Realtime / 案 C: Gemini Live のエンジンと切替 UI を削除。TTS 切替はモデル調整が終わるまで温存）
- [ ] 会話履歴の永続化（SwiftData、端末内のみ）
- [ ] 会話画面の UI
- [ ] セッション後のフィードバック生成
