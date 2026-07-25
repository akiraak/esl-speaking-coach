# TODO

## 1. 方針決定 / 調査

- [ ] 音声レイヤの技術検証と方式決定 [plan](docs/plans/voice-layer-spike.md)
  - [x] Phase 0: TTS / STT / 単一モデル speech-to-speech の候補の机上調査（2026-07-24、プラン付録に記録）
  - [x] 旧 Phase 1: iOS 純正音声のプロトタイプ → **純正不採用の決定により実測前に中止**（2026-07-24。プロバイダ非依存の資産は案 A2 へ流用、記録はプラン参照）
  - [ ] Phase 1: 案 A2（クラウド STT + Claude + クラウド TTS、OpenAI キー 1 本）のプロトタイプと実測
    - [ ] OpenAI API キーの取得と 2 キー管理対応（Keychain の `openai-api-key` アカウント・`.secrets/openai-api-key` シード）
    - [ ] STT: `gpt-4o-transcribe` の WebSocket ストリーミング実装（`UtteranceTranscriber` を置換）
    - [ ] TTS: `gpt-4o-mini-tts` のストリーミング再生実装（`SentenceSpeaker` の AVSpeech 実装を置換）
    - [ ] 実機実測（レイテンシ中央値・barge-in・日本語アクセント英語の STT 精度・TTS 品質）
    - 精度・終端検知に不満なら STT は Deepgram Flux、TTS は Cartesia へ差し替え（プラン付録）
  - [ ] Phase 2: 案 B（OpenAI Realtime `gpt-realtime-2.1-mini`、Phase 1 と同じ OpenAI キー）のプロトタイプと実測
  - [ ] Phase 3: 案 C（Gemini Live、現行モデル Gemini 3.1 Flash Live）のプロトタイプと実測
    - [ ] Gemini API キーの取得と 3 キー管理対応（Keychain の `gemini-api-key` アカウント・`.secrets/gemini-api-key` シード）
    - [ ] Live API の WebSocket 自前実装（`VoiceSession` 実装として追加。公式 Swift SDK なし）
    - [ ] 実機実測（レイテンシ中央値・barge-in・日本語アクセント英語の認識・transcript 品質）
  - [ ] Phase 4: 案 A2 / 案 B / 案 C の実測比較で方式を決定し `CLAUDE.md` を更新
    - 事前に「会話中の発音指摘を製品価値とするか」を決める（単一モデル方式（案 B / C）が構造的に有利なため判断に効く）

## 2. 実装（音声レイヤの方式決定後）

- [ ] 音声入出力の本実装（スパイクの `VoiceSession` 実装を製品品質に引き上げる）
- [ ] 会話履歴の永続化（SwiftData、端末内のみ）
- [ ] 会話画面の UI
- [ ] セッション後のフィードバック生成
