# TODO

## 方針決定 / 調査

- [ ] 音声レイヤの技術検証と方式決定 [plan](docs/plans/voice-layer-spike.md)
  - [ ] Phase 1: 案 A（iOS 内蔵音声 + Claude ストリーミング）のプロトタイプと実測
  - [ ] Phase 2: 案 B（OpenAI Realtime API）のプロトタイプと実測
  - [ ] Phase 3: 比較結果をもとに方式を決定し `CLAUDE.md` を更新

## セットアップ

- [ ] Xcode プロジェクトの作成（SwiftUI / iOS ネイティブ）
- [ ] `.gitignore` に Xcode 関連と API キーを含む設定ファイルを追加
- [ ] API キーを Keychain に保存する仕組みを実装

## 実装

- [ ] 音声入出力の抽象境界（`VoiceSession` 相当のプロトコル）を定義する
- [ ] Claude API クライアント（`URLSession` + SSE パース）を実装する
- [ ] 会話履歴の永続化（SwiftData、端末内のみ）
- [ ] 会話画面の UI
- [ ] セッション後のフィードバック生成
