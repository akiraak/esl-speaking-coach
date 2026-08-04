# TODO

## 機能

- [ ] iPhoneのボリュームを下げても読み上げ音量が下がらない

## 不具合

- [ ] 声を出していないのに入力終了 → 開始のジングルが鳴る [plan](docs/plans/empty-segment-no-cue.md)
  - ノイズで VAD だけ発火し、確定テキストが空だった経路。空と分かったターンは無音で通す
  - [ ] 実機確認: 物音で鳴らないこと / 通常発話で終了ジングルの遅れが不自然でないこと
- [ ] 会話終了ボタンを押したらアプリが落ちた [plan](docs/plans/end-session-crash.md)
- [ ] 会話終了後のフィードバックの文章が途中で途切れる [plan](docs/plans/feedback-truncated.md)
- [ ] 読み上げが途中で止まることが起きるかチェック
