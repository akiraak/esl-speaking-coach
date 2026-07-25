# TODO

## 1. セットアップ（最優先・全タスクの前提）

- [ ] プロジェクトセットアップ [plan](docs/plans/project-setup.md)
  - [ ] Phase 1: `CLAUDE.md` の開発環境制約を実態に合わせて更新（Mac + Xcode 26.5、ローカルでビルド・シミュレータ確認が可能）
  - [ ] Phase 2: Xcode プロジェクト作成（SwiftUI / iOS ネイティブ、XcodeGen で宣言的に管理）と `.gitignore` の Xcode 対応
  - [ ] Phase 3: API キーの Keychain 保存の最小実装（読み書きラッパ + 登録用の設定画面）

## 2. 方針決定 / 調査

- [ ] 音声レイヤの技術検証と方式決定 [plan](docs/plans/voice-layer-spike.md)
  - [ ] Phase 1: 案 A（iOS 内蔵音声 + Claude ストリーミング）のプロトタイプと実測
    - `VoiceSession` 相当のプロトコル定義と Claude API クライアント（`URLSession` + SSE）はこのフェーズで実装する
    - プロトタイプの動作確認はシミュレータで可。レイテンシ等の実測は実機で行う
  - [ ] Phase 2: 案 B（OpenAI Realtime API）のプロトタイプと実測
  - [ ] Phase 3: 比較結果をもとに方式を決定し `CLAUDE.md` を更新

## 3. 実装（音声レイヤの方式決定後）

- [ ] 音声入出力の本実装（スパイクの `VoiceSession` 実装を製品品質に引き上げる）
- [ ] 会話履歴の永続化（SwiftData、端末内のみ）
- [ ] 会話画面の UI
- [ ] セッション後のフィードバック生成
