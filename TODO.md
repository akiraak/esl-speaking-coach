# TODO

- [ ] gpt-live-transcribe への対応（クライアント側発話終端検知 + 手動 commit） [plan](docs/plans/gpt-live-transcribe-adoption.md)
  - [ ] Phase 1: `ClientSpeechEndpointer`（クライアント VAD の状態機械）+ ユニットテスト
  - [ ] Phase 2: live 用の送信ゲート・commit の組み込み（4o 経路は不変）
  - [ ] Phase 3: シミュレータ E2E + 実機検証（精度・終端の体感・barge-in・課金実測）
  - [ ] Phase 4: 採用判断と既定モデル切替（gpt-4o-transcribe へ戻せる状態は維持）

## 不具合

- [ ] 会話終了ボタンを押したらアプリが落ちた [plan](docs/plans/end-session-crash.md)
- [ ] 会話終了後のフィードバックの文章が途中で途切れる [plan](docs/plans/feedback-truncated.md)
