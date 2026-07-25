# DONE

- 2026-07-24 音声レイヤ検証 Phase 1: 案 B（OpenAI Realtime `gpt-realtime-2.1-mini`）のプロトタイプ実装と実機動作確認 [plan](docs/plans/voice-layer-spike.md)
  - WebSocket 自前実装（GA 形式のイベント仕様をテストで固定）+ 24kHz PCM16 ストリーミング再生 + サーバ VAD / barge-in。会話画面にエンジン切替（ターン制+Claude / OpenAI Realtime）を追加
  - OpenAI キーの 2 キー管理（Keychain `openai-api-key`・`.secrets/openai-api-key` シード・`-seed-openai-key`）
  - シミュレータ E2E（テキスト入力→音声応答、体感 571ms）と実機での音声会話・英語のみ応答を確認。レイテンシ中央値等の詳細計測は Phase 4 の比較時に実施
- 2026-07-24 音声レイヤ検証 Phase 0: TTS / STT / 単一モデル speech-to-speech 候補の机上調査（プラン付録に記録） [plan](docs/plans/voice-layer-spike.md)
- 2026-07-24 音声レイヤ検証・旧 Phase 1: iOS 純正音声（SpeechTranscriber + AVSpeechSynthesizer）+ Claude のプロトタイプ実装 → **iPhone 純正不採用の方針転換により実測前に中止** [plan](docs/plans/voice-layer-spike.md)
  - `VoiceSession` 境界・状態機械・Claude SSE クライアント（実キー E2E 検証済み）・会話 UI は案 A2 に流用
  - 中止理由: STT の数百 MB モデル DL、シミュレータ検証不可、AVSpeech の TTS 品質
- 2026-07-24 API キーを git 管理外のローカルファイル（`.secrets/anthropic-api-key`）から設定できるようにした [plan](docs/plans/archive/api-key-local-file.md)
  - `run-install-iphone.sh` と新規 `run-simulator.sh` が起動引数 `-seed-anthropic-key` で Keychain へシード（DEBUG のみ）
  - `.gitignore` に `.secrets/` を追加、`CLAUDE.md` セキュリティ節に手順を記載
- 2026-07-24 プロジェクトセットアップ [plan](docs/plans/archive/project-setup.md)
  - `CLAUDE.md` の開発環境を Mac + Xcode 26.5 前提に更新
  - XcodeGen（`project.yml`）で Xcode プロジェクトを作成し、`.gitignore` を Xcode 対応
  - API キーの Keychain 保存を実装（`KeychainStore` + 設定画面 + 起動時誘導、ユニットテスト付き）
- 2026-07-24 プロジェクト方針を `CLAUDE.md` に記載（プロダクト概要、技術スタック、音声レイヤの方針、Claude API の利用規約、開発環境の制約、セキュリティ）
