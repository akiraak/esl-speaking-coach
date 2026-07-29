# TODO

## 機能

- [ ] 通常の会話モード以外に単語の練習モードを作成する [plan](docs/plans/word-practice-mode.md)
  - 会話モードと単語（熟語を含む）を切りかられる
  - Chobiが先生役、Narukoがユーザーと一緒に学ぶ生徒役として会話を進めながら学習する
  - 練習する単語はユーザーが入力する / 1 セッション 1 語 / モード切替はヘッダ（📊 の左）
  - Phase 1〜5 は完了（実機確認まで済み）。追加の作業を続けるので親項目は開けたままにする
  - [ ] ヘッダのモード切替をタップ → 2 つを表示して選択する形にする [plan](docs/plans/practice-mode-picker.md)

## 不具合

- [ ] 会話終了ボタンを押したらアプリが落ちた [plan](docs/plans/end-session-crash.md)
- [ ] 会話終了後のフィードバックの文章が途中で途切れる [plan](docs/plans/feedback-truncated.md)
