# TODO

## 機能

## 不具合

- [ ] 会話終了ボタンを押したらアプリが落ちた [plan](docs/plans/end-session-crash.md)
  - [x] Phase 0: 診断ログの実装（次に落ちたら管理画面「診断」タブで確認する）
  - [ ] Phase 1: 再現の切り分け（状態 × 入力モード × 発話数）
  - [ ] Phase 2: 仮説の検証と原因確定
  - [ ] Phase 3: 対策
  - [ ] Phase 4: テスト追加・実機確認・後片付け

- [ ] 会話終了後のフィードバックの文章が途中で途切れる [plan](docs/plans/feedback-truncated.md)
  - [x] Phase 1: 診断ログの注入（エラーログの注入。挙動は変えない）
  - [ ] Phase 2: 再現待ちと原因確定
  - [ ] Phase 3: 対策
  - [ ] Phase 4: テスト・確認・後片付け

- [ ] イヤフォンで動くようにする
