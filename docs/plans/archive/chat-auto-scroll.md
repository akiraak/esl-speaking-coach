# トークルームの自動スクロール修正

## 目的・背景

TODO「新しい会話が表示されたら自動で1番下までスクロール」。

`ChatRoomView` には既に自動スクロール実装（`ScrollViewReader` + 最下部アンカー + `isAutoScrollEnabled`）が
入っているが、実際には効いていない。シミュレータで起動すると、タイムライン最下部（トピックカード）ではなく
履歴の途中で止まる。

## 現状調査

`EslSpeakingCoach/Conversation/ChatRoomView.swift` の `timeline`:

- `LazyVStack` の末尾に `Color.clear.frame(height: 1).id(bottomAnchorID)` を置き、
  `store.timelineRevision` / `partialTranscript` / `voiceState` の変化で
  `proxy.scrollTo(bottomAnchorID, anchor: .bottom)` している
- `onScrollPhaseChange` で `.tracking` / `.interacting` になったら自動スクロールを止め、
  `.idle` で「最下部から 120pt 以内か」を見て再開している

推定原因は 2 点。

1. **起動直後に最下部へ行かない**
   `store.onAppear()`（= 直近 10 セッションの履歴復元 + トピックカード投稿）は
   ビューの `.onAppear` から呼ばれるため、初期レイアウト後に大量のアイテムが積まれる。
   `LazyVStack` は画面外セルの高さを推定値で扱うため、この時点の `scrollTo` はズレた位置に着地する。
2. **`.idle` の再判定が自動スクロール自体を殺す**
   プログラム側のアニメーション付き `scrollTo` も `.animating` → `.idle` と遷移する。
   `.idle` ハンドラは「ユーザー操作だったか」を問わずジオメトリで再判定するため、
   コンテンツが伸びた直後の古い（あるいは追記中の）ジオメトリで判定して
   `isAutoScrollEnabled = false` に落ちてしまうことがある。一度落ちると以降ずっと追従しない。

## 対応方針

`ChatRoomView.swift` の `timeline` のみを変更する（ストア・モデルは変更しない）。

1. `ScrollView` に `.defaultScrollAnchor(.bottom, for: .initialOffset)` を付け、初期表示を最下部にする
2. 初期表示の取りこぼし対策として、初回のみアニメーション無しで最下部へ寄せる
   （`LazyVStack` の高さ推定が確定するまで数フレーム待つ）
3. `onScrollPhaseChange` の `.idle` 再判定を「直前がユーザー操作フェーズだったとき」に限定し、
   プログラム側スクロールの完了で `isAutoScrollEnabled` が落ちないようにする

## 影響範囲

- `EslSpeakingCoach/Conversation/ChatRoomView.swift`（UI のみ）
- 会話ロジック・永続化・音声レイヤへの影響なし

## テスト方針

SwiftUI のスクロール挙動はユニットテストで検証できないため、シミュレータでの目視確認を主とする。

- 起動直後にタイムライン最下部（トピックカード）が見えること
- 会話中（`-start-conversation -send-text ...`）で新しい発話・ストリーミング伸長に追従すること
- 手動で上に遡っている間は勝手に下へ飛ばないこと / 最下部付近まで戻すと追従が再開すること
