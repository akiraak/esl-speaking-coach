# TODO

- [ ] 単語モードで未学習のものを辞書からランダムで選択して会話を始める [plan](docs/plans/wordbook-random-word.md)
  - [ ] Phase 1: 取得・選択ロジック（fetchAllWords / 練習済み除外の純関数 / 単体テスト）
  - [ ] Phase 2: UI とセッション開始（カードの「ランダムに選ぶ」ボタン / エラー表示 / `-start-random-word`）
  - [ ] Phase 3: 検証（単体テスト・シミュレータ E2E・実機はユーザー）

## 不具合

- [ ] 会話終了ボタンを押したらアプリが落ちた [plan](docs/plans/end-session-crash.md)
- [ ] 会話終了後のフィードバックの文章が途中で途切れる [plan](docs/plans/feedback-truncated.md)
