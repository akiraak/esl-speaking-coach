# 自分が話すターンのときのみ音声入力を動かす（開始 / 終了ジングル付き）

2026-07-31 作成。

## 進捗（2026-07-31）

- **Phase 1 完了**: `AudioTapRouter.setSpeechGateOpen(_:) -> Bool`（attach 直後は閉。閉時は
  gated 処理を丸ごとスキップ、閉じる際にエンドポインタ / 遡りをリセットし、発話中セグメントの
  破棄を戻り値で通知）。`TurnBasedVoiceSession.syncVoiceInputGate()` が state didSet と
  マイク再アタッチ時に `state == .listening && 音声入力有効` へ同期。破棄時は
  `input_audio_buffer.clear`（`clearClientBuffer` 新設）+ `isUserSpeaking` / レベルセグメント /
  partial 表示のリセット。4o 経路は不変
- **Phase 2 完了**: `ListeningCue` を `Kind.start`（上昇 E5→A5）/ `.end`（下降 A5→E5）の
  2 種に拡張し、`StreamingAudioPlayer.playCue(_:)` / `CloudSentenceSpeaker.playInputEndCue()` を
  追加。終了音は `.speechStopped` 受信時（テキスト送信ターンでは鳴らない）、開始音は従来の
  listening 入りに加えて空セグメントで listening に戻るパスでも鳴らし直す
- **Phase 3 完了**: ゲート開閉 3 件 + clear JSON 1 件 + ジングル 2 件のテスト追加で
  全 305 件パス。シミュレータのテキスト会話回帰 OK。実機確認（ターン外で入力が動かない・
  ジングル 2 種の聞こえ方）もユーザー実施で問題なし → タスク完了

## 目的・背景

- 現状は live（クライアント VAD）でもマイク入力の判定がセッション中ずっと動いており、AI の読み上げ中の回り込み・環境音で VAD が誤発火して割り込み扱いになったり、意図しないセグメントが append されることがある
- **音声入力は「自分が話すターン（listening）」のときだけ動かす**。AI が考え中・読み上げ中（thinking / speaking）は入力を止め、ターンの取り合いを明確にする
- 入力の窓がいつ開いていつ閉じたかを耳で分かるように、**入力開始と入力終了で別のジングル**を鳴らす（現在は listening 入りの開始ジングル 1 種のみ）

## 対応方針

### Phase 1: 入力ゲート（listening のときだけクライアント VAD を動かす）

- `AudioTapRouter` に `setSpeechGateOpen(_:) -> Bool` を追加。閉じている間は live の送信ゲート処理（エンドポインタ判定・遡りバッファ蓄積・append）を丸ごとスキップする。暗騒音の推定（meter）とレベル表示は止めない
- 閉じるときにエンドポインタと遡りバッファをリセット。**発話中セグメントを破棄した場合は true を返し**、呼び出し側で `input_audio_buffer.clear` を送ってサーバ側の append 済み音声も破棄する（テキスト送信で発話途中に割り込んだケース。放置すると次セグメントの commit に混入する）
- `TurnBasedVoiceSession` は state の変化で `state == .listening && 音声入力有効` に同期する（マイク再アタッチ直後も明示同期）。破棄時は `isUserSpeaking` と計測中のレベルセグメントも合わせてリセット
- **帰結: 音声での barge-in は無効になる**（AI 発話中は音声入力ごと止まるため）。割り込み手段は一時停止ボタンとテキスト送信のみ。これは仕様変更として `CLAUDE.md` に反映する
- **4o（サーバ VAD）経路は不変**（常時ストリーム + サーバ VAD の従来挙動。比較用に温存している旧経路のため）

### Phase 2: 入力開始 / 終了の 2 ジングル

- `ListeningCue` に種別（`Kind.start` / `.end`）を追加。開始は現行の上昇 2 音（E5→A5）、終了は聞き分けられる下降 2 音（A5→E5）
- `StreamingAudioPlayer.playCue` を種別付きにし、`CloudSentenceSpeaker` に `playInputEndCue()` を追加（既存の cue 専用ノードを共用。TTS のターン管理とは独立）
- 鳴らすタイミング:
  - **開始**: listening 入り（既存の `playListeningCueIfListening`）。加えて、空セグメント（雑音・エコー破棄等）で listening に戻るパスでも鳴らし直す（入力が再開したことを知らせる）
  - **終了**: `.speechStopped`（発話終端 = 入力の窓が閉じる）で鳴らす。テキスト送信ターンでは鳴らさない（音声入力していない）

### Phase 3: テスト・回帰・実機確認

- ユニット: ゲート開閉（閉時は発話しても無イベント / 破棄の戻り値 / 再開後は通常動作）、`input_audio_buffer.clear` の JSON、終了ジングルの波形（無音でない・クリックなし・短い）
- シミュレータ: テキスト会話回帰（音声パスは対象外）+ 全テスト
- 実機（ユーザー）: ターン外で入力が動かないこと、ジングル 2 種の聞こえ方、空セグメント時の開始音の鳴り直し

## 影響範囲

- `Voice/MicrophoneCapture.swift`（ゲート開閉）/ `TurnBasedVoiceSession.swift`（同期・ジングル配線）/ `OpenAITranscriptionStream.swift` + `OpenAITranscriptionProtocol.swift`（clear）/ `ListeningCue.swift` + `StreamingAudioPlayer.swift` + `CloudSentenceSpeaker.swift`（ジングル）
- 仕様変更: 音声 barge-in の廃止（`CLAUDE.md` の音声レイヤの方針を更新）
- 4o 経路・テキスト入力モード・保存データには影響しない

## テスト方針

- ユニット: `AudioTapRouterGateTests` にゲート開閉ケースを追加、`ListeningCueTests` に終了音、`CloudPipelineProtocolTests` に clear の JSON
- シミュレータ E2E + 実機（Phase 3 参照）
