# 空セグメントのときは入力ジングルを鳴らさない

## 目的・背景

声を出していないのに「入力終了ジングル → （テキストなし） → 入力開始ジングル」が鳴ることがある、
という実機報告。コードを追うと**仕様どおりの経路**で、誤検知した無音セグメントを捨てて
入力窓を開き直した音だった。

1. クライアント VAD（`ClientSpeechEndpointer`）が物音で発話開始と判定する（この時点では無音）
2. 0.8 秒の無音で終端 → `handleSTT(.speechStopped)` が**その場で終了ジングルを鳴らし**、
   `thinking` へ移って入力ゲートを閉じる（`TurnBasedVoiceSession.swift:505-517`）
3. 確定テキストが空 / レベルゲート棄却 / プロンプトのエコー → `pendingTurnText` が空のまま
4. `commitPendingTurnIfReady()` が `listening` へ戻し、**開始ジングルを鳴らす**（`:586-600`）

静かな部屋では暗騒音がほぼ 0 で閾値が下限の `minimumPeak` 0.01 まで下がるため、衣擦れ・
キーボード・息でも 0.12 秒を超えれば 1 の判定は起きうる。閾値を上げると本人の発話の取りこぼしに
直結するので、**閾値ではなく「空だと分かったターンは音を鳴らさない」側で直す**。

## 対応方針

終了ジングルを「発話終端の瞬間」ではなく「**確定テキストが空でないと分かった瞬間**」に鳴らす。

- `.speechStopped` では鳴らさず、`pendingInputEndCue` フラグを立てるだけにする
- `commitPendingTurnIfReady()` の非空パスでフラグを消費して鳴らす
- 空パスではフラグを落として**何も鳴らさず**静かに `listening` へ戻す。ここで開始ジングルも
  鳴らさない（終了ジングルが鳴っていないのに開始ジングルだけ鳴ると、正体不明の単発音になる）
- STT 切断・入力オフ・ゲート途中クローズではフラグを落とす（次のターンへ持ち越さない）

結果、ノイズ誤検知の一連（開始判定 → 終端 → 空）は**完全に無音**で通り過ぎる。

### トレードオフ

- 終了ジングルが STT の確定待ち（`sttFinalizeMs`）ぶん遅れる。無音 0.8 秒の待ちの後なので
  体感で「話し終わり → 少し置いて終了音」になる。実機で不自然でないか確認する
- 本人が実際に話したのに STT が空を返した / 認識失敗したケースでは、従来は 2 音鳴って
  「聞き取りへ戻った」と分かったが、今後は無音になる。状態は listening のままなので
  話し直せばよい。会話ログには従来どおり 1 行残る

## 影響範囲

- `EslSpeakingCoach/Voice/TurnBasedVoiceSession.swift` のみ（`pendingInputEndCue` 追加、
  `.speechStopped` / `commitPendingTurnIfReady` / `tearDownSTT` / `handleSTTConnectionLost` /
  `syncVoiceInputGate` の分岐）
- `ListeningCue` / `CloudSentenceSpeaker` / 送信ゲート（`AudioTapRouter`）は変更なし
- 4o 経路（サーバ VAD・常時入力）も同じ `handleSTT` を通るため、セグメントごとではなく
  ターンごとに 1 回鳴る形へ変わる（従来より鳴る回数が減るだけ）

## テスト方針

- `xcodebuild` でビルド + 既存テスト（`ListeningCueTests` / `AudioTapRouterGateTests` ほか）が通ること
- 実機確認（`TurnBasedVoiceSession` はネットワーク + AVFoundation 依存でユニットテスト不可）
  - 黙って座っていて物音を立てたとき、ジングルが鳴らないこと（管理画面の会話ログに
    「STT セグメント …「」」の行だけが残る）
  - 普通に話したとき、従来どおり終了 → 応答 → 開始のジングルが鳴ること・終了ジングルの
    遅れが不自然でないこと
