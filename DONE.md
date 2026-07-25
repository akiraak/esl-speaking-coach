# DONE

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
