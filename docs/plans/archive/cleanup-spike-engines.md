# 検証用コードの整理（案 B / 案 C エンジンと切替 UI の削除）

## 目的・背景

音声レイヤは 2026-07-25 に案 A2（ターン制+Claude + Gemini TTS）で確定した（`docs/plans/archive/voice-layer-spike.md`）。
比較検証のために残っている不採用エンジン（案 B: OpenAI Realtime / 案 C: Gemini Live）とエンジン切替 UI を削除し、
以降の実装タスク（会話画面の UI・履歴永続化）が触るコードを採用構成だけにする。

- **TTS 切替（Gemini / OpenAI の Picker と `-tts-provider`）は温存する**（TODO の決定どおり、モデル調整が終わるまで）
- API キーは 3 つとも引き続き必要（Claude=会話 / OpenAI=STT・比較用 TTS / Gemini=TTS）なので Keychain まわりは触らない

## 対応方針

### 削除

| 対象 | 内容 |
| --- | --- |
| `Voice/Realtime/RealtimeProtocol.swift` / `RealtimeVoiceSession.swift` | 案 B 本体（`RealtimeAudioPlayer.swift` は下記のとおり温存・移動） |
| `Voice/GeminiLive/`（フォルダごと） | 案 C 本体（`GeminiLiveProtocol.swift` / `GeminiLiveVoiceSession.swift`） |
| `EslSpeakingCoachTests/RealtimeProtocolTests.swift` / `GeminiLiveProtocolTests.swift` | 案 B / C のプロトコルテスト |
| `VoiceSession.swift` の `VoiceEngine` enum | エンジン選択肢そのもの |
| `ConversationViewModel.engine` と `start()` の switch | 常に `TurnBasedVoiceSession` を生成する形に |
| `ConversationView` の `enginePicker` | ナビゲーションタイトルも `engine.label` 依存をやめ固定文言に |
| `DebugLaunchArguments.voiceEngineOverride`（`-voice-engine`） | `-tts-provider` は残す |

### 温存・移動

- `RealtimeAudioPlayer.swift` は採用パイプラインの `CloudSentenceSpeaker` が再生に使用しているため温存。
  `Voice/Realtime/` フォルダを消すのに合わせて `Voice/CloudPipeline/` へ移動し、
  スパイク由来の名前を実態に合わせて `StreamingAudioPlayer` にリネームする（参照は `CloudSentenceSpeaker` と `GeminiTTSClient` のコメントのみ）
- TTS 切替（`TTSProvider` / `ttsPicker` / `-tts-provider` / `OpenAITTSClient`）は現状のまま

### ドキュメント

- `docs/specs/ai-cost-map.md`: 「6. 検証用エンジン（削除予定）」の行とセクションを削除（現状マップなので、無くなったものは載せない）

## 影響範囲

上表のとおり。`project.yml` はフォルダ参照なのでファイル削除後に `xcodegen generate` するだけで良い。
`run-simulator.sh` / `run-install-iphone.sh` に `-voice-engine` の使用箇所は無い。

## テスト方針

- `xcodegen generate` + `xcodebuild`（シミュレータ）でビルドとユニットテストが通ること
- シミュレータ E2E: `-start-conversation -send-text` でターン制会話（Claude 応答 + TTS 再生）が退行していないこと
