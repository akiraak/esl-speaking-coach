# TODO

- [ ] Alibaba 音声モデル（Qwen3-TTS / Qwen3-ASR）の実機検証（現行比 約 1/3 の単価・無料枠で検証可。LLM 置き換えより節約が大きい月 約 $5。出典: [cheap-chinese-ai-models.md](docs/plans/archive/cheap-chinese-ai-models.md) の Phase 1・Phase 4）[plan](docs/plans/alibaba-voice-models.md)
  - [x] Phase 1: Mac 上での疎通・品質・レイテンシ検証（scratchpad スクリプト。voice 実聴・選定は Phase 3.5 へ統合）
  - [x] Phase 2: アプリ組み込み（切替可能な実装追加、既定は現行のまま。シミュレータ E2E まで確認済み）
  - [x] Phase 3: 実機検証（2026-08-01 完了。ASR 問題なし / TTS は voice のキャラ合わせが必要）
  - [x] Phase 3.5: TTS voice のキャラ合わせ（2026-08-01 完了。instruct 変種で Chobi=Serena×casual / Naruko=Vivian×bright に確定）
  - [ ] Phase 4: 判断とまとめ（採否決定・プランへ記録）


- [ ] チャット欄英語の再読み上げ

## 不具合

- [ ] 会話終了ボタンを押したらアプリが落ちた [plan](docs/plans/end-session-crash.md)
- [ ] 会話終了後のフィードバックの文章が途中で途切れる [plan](docs/plans/feedback-truncated.md)
