# TODO

## 1. 方針決定 / 調査

- [ ] 音声レイヤの技術検証と方式決定 [plan](docs/plans/voice-layer-spike.md)
  - [ ] Phase 2: 案 C（Gemini Live、現行モデル Gemini 3.1 Flash Live）のプロトタイプと実測
    - [ ] Gemini API キーの取得と 3 キー管理対応（Keychain の `gemini-api-key` アカウント・`.secrets/gemini-api-key` シード）
    - [ ] Live API の WebSocket 自前実装（`VoiceSession` 実装として追加。公式 Swift SDK なし）
    - [ ] 実機実測（レイテンシ中央値・barge-in・日本語アクセント英語の認識・transcript 品質）
  - [ ] Phase 3: 案 A2（クラウド STT + Claude + クラウド TTS）のプロトタイプと実測。STT / TTS は代替モデルも含めて比較する
    - [ ] STT: `gpt-4o-transcribe` の WebSocket ストリーミング実装（`UtteranceTranscriber` を置換。Phase 1 の OpenAI キーを共用）
    - [ ] TTS: `gpt-4o-mini-tts` のストリーミング再生実装（`SentenceSpeaker` の AVSpeech 実装を置換）
    - [ ] STT 代替: Deepgram Flux を同条件で実測比較（end-of-turn 検知ネイティブ。要 Deepgram キー）
    - [ ] TTS 代替: Cartesia Sonic を同条件で実測比較（TTFA 40ms。要 Cartesia キー）
    - [ ] 実機実測（レイテンシ中央値・barge-in・日本語アクセント英語の STT 精度・TTS 品質。STT / TTS の組み合わせごとに記録）
  - [ ] Phase 4: 案 A2 / 案 B / 案 C の実測比較で方式を決定し `CLAUDE.md` を更新
    - 事前に「会話中の発音指摘を製品価値とするか」を決める（単一モデル方式（案 B / C）が構造的に有利なため判断に効く）

## 2. 実装（音声レイヤの方式決定後）

- [ ] 音声入出力の本実装（スパイクの `VoiceSession` 実装を製品品質に引き上げる）
- [ ] 会話履歴の永続化（SwiftData、端末内のみ）
- [ ] 会話画面の UI
- [ ] セッション後のフィードバック生成
