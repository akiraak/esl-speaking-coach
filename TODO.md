# TODO

- [ ] Alibaba 音声モデル（Qwen3-TTS / Qwen3-ASR）の実機検証（現行比 約 1/3 の単価・無料枠で検証可。LLM 置き換えより節約が大きい月 約 $5。出典: [cheap-chinese-ai-models.md](docs/plans/archive/cheap-chinese-ai-models.md) の Phase 1・Phase 4）[plan](docs/plans/alibaba-voice-models.md)
  - [x] Phase 1: Mac 上での疎通・品質・レイテンシ検証（scratchpad スクリプト。**voice サンプルのユーザー実聴のみ残**）
  - [x] Phase 2: アプリ組み込み（切替可能な実装追加、既定は現行のまま。シミュレータ E2E まで確認済み）
  - [ ] Phase 3: 実機検証（実セッションで TTS 品質・ASR 精度・レイテンシ体感。`./run-install-iphone.sh -tts-provider qwen -stt-model qwen3-asr-flash-realtime`）
  - [ ] Phase 4: 判断とまとめ（採否決定・プランへ記録）

## 不具合

- [ ] 会話終了ボタンを押したらアプリが落ちた [plan](docs/plans/end-session-crash.md)
- [ ] 会話終了後のフィードバックの文章が途中で途切れる [plan](docs/plans/feedback-truncated.md)
