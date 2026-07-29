# TODO

## 機能

- [ ] 通常の会話モード以外に単語の練習モードを作成する [plan](docs/plans/word-practice-mode.md)
  - 会話モードと単語（熟語を含む）を切りかられる
  - Chobiが先生役、Narukoがユーザーと一緒に学ぶ生徒役として会話を進めながら学習する
  - 練習する単語はユーザーが入力する / 1 セッション 1 語 / モード切替はヘッダ（📊 の左）
  - [x] Phase 1: モードの土台（`PracticeMode` / `ChatRoomStore.practiceMode` / `modeRawValue` / `recentWords`）
    - 実機でのマイグレーション確認は未実施 → Phase 5 へ持ち越し
  - [x] Phase 2: 切替 UI とカード（ヘッダのモードピル / `TopicCard.mode` と単語カード / 入力アラートの文言 / 切替時のカード差し替え）
    - ピルのタップ切替は実機で確認する（simctl でタップできないため未確認）→ Phase 5
  - [x] Phase 3: 単語モードのセッション（`WordCoachSystemPrompt` / `Configuration.practiceMode` / `[New word: X]` / `[end]` 抑止 / `rebuildHistory` と文言）
    - `[end]` が実際に出るケースは未観測（モデルが吐かなかった）→ 実装側の抑止は単体テストのみ
  - [ ] Phase 4: セッション後（フィードバックの `Practice word:` / 記憶ノート更新のスキップ / 管理画面のモード表示）
  - [ ] Phase 5: 検証と後片付け（単体テスト / シミュレータ E2E / 実機確認 / `docs/specs/word-practice.md` / 仕様書更新）

## 不具合

- [ ] 会話終了ボタンを押したらアプリが落ちた [plan](docs/plans/end-session-crash.md)
- [ ] 会話終了後のフィードバックの文章が途中で途切れる [plan](docs/plans/feedback-truncated.md)
