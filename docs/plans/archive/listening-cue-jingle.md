# 入力待ちの前にジングルを鳴らす

## 目的・背景

音声会話中、AI の読み上げが終わって自分のターン（listening）になったことが画面を見ないと分からない。
入力待ちへ入るタイミングで短いジングル（チャイム音）を鳴らし、「話してよい」ことを耳で分かるようにする。

## 対応方針

- **音源はコードで合成する**（音源ファイルは持たない）。2 音の短い上昇チャイム（サイン波 + アタック/リリース包絡、合計 0.3 秒弱、控えめな音量）を 24kHz Float32 mono で生成する
  - 生成ロジックは `ListeningCue`（純粋関数）として切り出し、単体テスト可能にする
- **再生は既存の `StreamingAudioPlayer` の AVAudioEngine に専用の `AVAudioPlayerNode` を 1 本追加**して行う
  - TTS 再生用ノードとは独立させ、ターン管理（マーカー・onTurnFinished 等）に影響を与えない
  - `playCue()` を公開し、`CloudSentenceSpeaker.playListeningCue()` 経由で `TurnBasedVoiceSession` から呼ぶ
  - UI / 会話ロジックには音声 API を漏らさない（CLAUDE.md の設計制約どおり、すべて VoiceSession 実装の内側で完結）
- **鳴らすタイミング**（`TurnBasedVoiceSession`）: 「ユーザーのターン待ちに入った」ときだけ
  - セッション開始で listening になったとき（AI 開始トピックがある場合は AI が先に話すので鳴らさない）
  - AI のターンが読み上げ完了して listening に戻ったとき（pending の user テキストで即次ターンに入る場合は鳴らさない）
  - STT 再接続完了 / suspend からの復帰で listening に戻ったとき
  - 鳴らさない: barge-in（ユーザーが既に話している）、VAD 誤発火で thinking → listening に戻るだけのとき、テキスト⇔音声のモード切替

## 影響範囲

- `EslSpeakingCoach/Voice/CloudPipeline/StreamingAudioPlayer.swift` — cue 用ノード追加 + `playCue()`
- `EslSpeakingCoach/Voice/CloudPipeline/ListeningCue.swift` — 新規（波形合成）
- `EslSpeakingCoach/Voice/CloudPipeline/CloudSentenceSpeaker.swift` — `playListeningCue()` 転送
- `EslSpeakingCoach/Voice/TurnBasedVoiceSession.swift` — listening 遷移時の呼び出し
- UI・会話ロジック・永続化には変更なし

## テスト方針

- 単体テスト（`ListeningCueTests`）: サンプル列が非空、振幅が ±1 に収まる、先頭・末尾がほぼ 0（クリックノイズ防止）
- `xcodebuild` でビルド + 既存テストのパスを確認
- 実際の鳴り方（音量・タイミングの体感）はシミュレータで確認。実機での聞こえ方は実機確認事項として明示する
