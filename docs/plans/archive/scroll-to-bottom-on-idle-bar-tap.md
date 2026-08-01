# チャット欄を 1 番下までスクロールさせる機能

## 目的・背景

タイムラインを上に遡ると自動追従が切れ（`isAutoScrollEnabled = false`）、最新のトピックカード / 単語カードへ戻るには手でスクロールし直すしかない。セッション未開始時に画面下の入力バーへ出ている案内（「トピックカードから話題を選んでスタート」「カードから練習する単語を入力してスタート」= `ChatInputBar` の `idleBar`）は「下にあるカードを見て」という誘導なので、**この案内のタップで最下部（カードの位置）までスクロールする**導線にする。

## 対応方針

1. `ChatRoomView` の `ScrollViewReader` を `timeline` 内から `body` の `VStack` 全体へ持ち上げ、入力バーからも `proxy` を使えるようにする（`timeline` は proxy を引数に取る形へ変更）
2. `ChatInputBar` に `onIdleTap: () -> Void` を追加し、`idleBar` を Button 化する（見た目は現状のテキストのまま。`.buttonStyle(.plain)` + `contentShape` で行全体をタップ可能に）
3. タップ時は `isAutoScrollEnabled = true` にして既存の `scrollToBottom(proxy)`（アニメーション + セトル処理）を呼ぶ

## 影響範囲

- `EslSpeakingCoach/Conversation/ChatRoomView.swift`（ScrollViewReader の位置・タップハンドラ）
- `EslSpeakingCoach/Conversation/ChatRoomComponents.swift`（`ChatInputBar` に onIdleTap 追加・idleBar の Button 化）

## テスト方針

- `xcodebuild` でビルドが通ること
- シミュレータ（iPhone 17）で確認:
  - セッション未開始で履歴を上に遡り、下の案内バーをタップすると最下部のカードまでスクロールする
  - タップ後は自動追従が再開する（以後の追記で最下部に張り付く）
  - セッション中（voice / text バー）・エラー再開バーの挙動は変わらない
