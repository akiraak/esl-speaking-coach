# 内蔵スピーカーから読み上げが鳴らない — 調査と対応

## 症状

実機（iPhone 14 Pro / iOS 26.5.2）で、**イヤフォンを繋いでいないときに読み上げが一切鳴らない**。
イヤフォン（Bluetooth）を繋いでいるときは鳴る。

## 切り分け（端末の診断ログ）

`xcrun devicectl device copy from --domain-type appDataContainer` で端末の `app.log` を取得して読んだ。

**(1) 鳴っていたセッション（Bluetooth 接続あり・15:58）**

```
route: 開始 出力=BluetoothHFP(OpenDots ONE) 入力=BluetoothHFP(OpenDots ONE) 16000Hz
route: 経路変更(rawValue: 3) 出力=BluetoothHFP(OpenDots ONE) …
```

外部出力があるので `needsSpeakerOverride` は false。オーバーライドを一度も呼ばず、経路も安定している。

**(2) 鳴らないセッション（イヤフォン無し・18:42 以降すべて）**

```
route: 開始       出力=Receiver(レシーバー) …
route: 出力を スピーカー へ切り替えた
route: 経路変更(rawValue: 3) 出力=Speaker(スピーカー) …
route: 出力を 既定 へ切り替えた            ← 自分で戻してしまう
route: 経路変更(rawValue: 3) 出力=Receiver(レシーバー) …
route: 出力を スピーカー へ切り替えた
…（数百 ms のあいだ往復）
!! player: エンジン停止中に enqueue が呼ばれた（クラッシュしうる）  ← 以後ずっとこれ（713 行）
```

## 原因

**(A) 経路判定が冪等でない（根本原因）**

`AudioRoutePolicy.needsSpeakerOverride` は「出力が内蔵レシーバーだけなら true」。
オーバーライドが効くと出力は `Speaker` になるので、次の評価で **false → `.none` に戻す** →
経路がレシーバーへ戻る → また true → … と往復する。
**自分のオーバーライドの結果を見て、自分でそれを取り消してしまう。**

`handleRouteChange` には `reason != .override` のガードがあるが、
**この端末では一連の経路変更が `.categoryChange`（rawValue 3）として通知される**ため
ガードに引っかからず、往復が止まらない。

**(B) 往復で止まった AVAudioEngine が誰にも再起動されない（無音になる直接の原因）**

経路変更でハードウェアのフォーマットが変わると `AVAudioEngine` は停止する。
`restartAudioIO` を呼ぶのは `.oldDeviceUnavailable` / `.newDeviceAvailable` の 2 理由だけなので、
`.categoryChange` で止まったエンジンは**誰も起こさない**。
以降 `StreamingAudioPlayer.enqueue` は止まったエンジンへ積み続け（ログを 1 行残すだけ）、
**音は 1 バイトも鳴らない**。

`docs/plans/archive/earphone-audio-route.md` の実機確認は **AirPods を繋いだ状態でのみ**行っており、
イヤフォン無し（= オーバーライドが走る唯一の経路）を実機で通していなかった。

## 対応方針

**(A) 判定を「外部の出力が居るか」で行う**

内蔵（レシーバー / スピーカー）だけなら常にスピーカーへ寄せる。
こうすると **Speaker のときも desired = `.speaker`** になり、呼び出し側の
「望む値が今と同じなら呼ばない」ガードでそのまま安定する（往復が起きない）。
イヤフォン・Bluetooth・AirPlay・CarPlay 等が 1 つでも居れば従来どおり OS に任せる。

**(B) 止まったエンジンを起こす**

`StreamingAudioPlayer` に `ensureEngineRunning()` を足し、`enqueue` の先頭で呼ぶ。
停止していたら `prepare()`（= `engine.start()`）で起こしてから積む。起こせなければ**積まずに捨てる**
（止まったエンジンへの `scheduleBuffer` は AVAudioEngine のアサートで abort しうるため。
`docs/plans/end-session-crash.md` の H1 と同じ経路で、そこも塞がる）。

## 影響範囲

- `Voice/AudioRoutePolicy.swift` — 判定の書き換え
- `Voice/CloudPipeline/StreamingAudioPlayer.swift` — エンジン再起動
- `EslSpeakingCoachTests/AudioRoutePolicyTests.swift` — 「既にスピーカーなら不要」は
  **バグの側を固定していたテスト**なので期待値を反転する
- `CLAUDE.md` / `docs/plans/archive/earphone-audio-route.md` の決定文の補足

**変更しない**: カテゴリ・モード・オプション（`.defaultToSpeaker` を使わない方針は維持）。

## テスト方針

- `AudioRoutePolicyTests`: 内蔵スピーカー単独で true（往復防止）、内蔵レシーバーで true、
  外部（有線 / BT HFP / BT A2DP / AirPlay）が混ざれば false、空なら false
- 実機確認（シミュレータでは経路が `.playback` 固定で再現しない）:
  - **イヤフォン無しで読み上げが内蔵スピーカーから鳴る**（今回の症状）
  - 診断ログに `route: 出力を 既定 へ切り替えた` の往復が出ない
  - Bluetooth を繋いだときは従来どおりそちらから鳴る（退行確認）

## 確認（2026-07-28）

- 単体テスト: `AudioRoutePolicyTests` を 3 件追加 / 1 件反転（内蔵スピーカー・AirPlay・
  内蔵 + 外部の混在）。XCTest 198 件 + swift-testing 12 件すべてパス
- 実機（イヤフォン無し）に入れて単語モードのセッションを自動実行し、端末のログを回収した:

```
route: 開始 出力=Receiver(レシーバー) 入力=MicrophoneBuiltIn 48000Hz
route: 出力を スピーカー へ切り替えた
route: 経路変更(rawValue: 3) 出力=Speaker(スピーカー) 入力=MicrophoneBuiltIn 48000Hz
…（以降 route の行は無し）
player: shutdown 開始 running=true playing=true pending=0
```

  往復（`出力を 既定 へ切り替えた`）は **0 回**、`エンジン停止中に enqueue` も **0 回**
  （直前の起動では 713 回）。終了時にエンジンは動作中 = 再生できていた。
  エンジンの再起動（`ensureEngineRunning` の保険）も発火していない
- **耳での確認はユーザーに依頼**（音が実際に鳴っているかはログでは断定できない）
- `run-install-iphone.sh` に `"$@"` を足し、`run-simulator.sh` と同じく起動引数を渡せるようにした
  （実機で E2E を回すのに必要だった）
