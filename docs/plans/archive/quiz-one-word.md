# クイズの出題数を 1 問にし、チャット欄に出題語を表示しない

## 目的・背景

- 5 語 1 周のクイズは 1 セッションが長く、もっと気軽に受けたい → **1 セッション 1 語**にする
  （`quizWordCount` の定数変更。増やしたくなったらこの 1 箇所を戻す）
- チャット欄（タイムライン）に出題語が出ると**答えが見えてクイズにならない**。
  現状はセッション区切り（`クイズ: put off`）と使用済みクイズカードの `selectedTitle` が
  クイズ開始と同時に語を表示してしまう。フィードバックカードの見出し（topicTitle）も
  終了後とはいえ語の羅列が残る → **チャット欄には出題語を一切出さない**

## 対応方針

1. `ChatRoomStore.quizWordCount` を 5 → **1** に変更（コメントも更新）
2. チャット欄から出題語を消す（保存・管理画面・フィードバック生成への入力は従来どおり語を持つ）:
   - セッション区切り `dividerLabel(mode: .quiz)` → 固定文言 **「クイズ」**（title を無視）
   - クイズカードの `quizBody` → 使用済みでも `selectedTitle`（出題語）を出さず、
     母集団の説明 caption のまま。文言は 1 語なので「最大」を外し
     `練習済み N語からランダムに1語を出題` にする
   - フィードバックカードの見出し → quiz のときは topicTitle の代わりに **「単語クイズ」**
     （フィードバック本文が語に触れるのは会話の内容そのものなので隠さない）
3. 管理画面（`🎯 <語>`）・SwiftData の `topicTitle`・出題済み除外・`[Quiz words: X]` は変えない
   （チャット欄だけの話。復習の記録と除外ロジックは語が要る）

## 影響範囲

- `ChatRoomStore.swift`（`quizWordCount` / `dividerLabel`）
- `ChatRoomComponents.swift`（`quizBody` / `FeedbackCardView`）
- テスト: `PracticeModeCardTests.testDividerLabelPerMode` の quiz 期待値を「クイズ」に変更。
  `QuizWordsTests` は count を引数で渡しているため変更不要

## テスト方針

- 単体テスト全パス
- シミュレータ E2E: クイズカードの caption が `…からランダムに1語を出題` / 開始後の区切りが
  「クイズ」だけ / 使用済みカード・フィードバックカードに語が出ない / 1 語で自動終了
