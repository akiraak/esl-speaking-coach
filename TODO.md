# TODO

## 機能

- [ ] 使用するモデルをアプリの管理画面から変更可能にする [plan](docs/plans/model-selection-in-admin.md)
  - 多くは Sonnet5 / Opus5 / Haiku4.5 の切り替え。TTS は Gemini / Qwen、STT は gpt-live-transcribe / Qwen
  - 管理画面が増えてきたので整理する（segmented 5 タブ → List + push）
  - [x] Phase 1: 管理画面を List + push へ組み替える（機能は現状維持・`-open-admin` 互換）
  - [x] Phase 2: Claude 系 5 経路（会話 / トピック / フィードバック / 記憶 / 翻訳）のモデル選択
  - [x] Phase 3: TTS / STT のプロバイダ・モデル選択（キー未設定表示・次のセッションから反映）
  - [x] Phase 4: 料金画面の追従（TTS の Qwen 固定のズレ修正込み）・診断ログ
  - [ ] 実機確認: モデルを切り替えて 1 セッション（haiku の effort 落とし・opus-5 の max_tokens・
        Qwen TTS / gpt-4o-transcribe の音声）+ モデル画面の下部（STT セクションと「すべて既定に戻す」）

- [ ] iPhoneのボリュームを下げても読み上げ音量が下がらない

## 不具合

- [ ] 会話終了ボタンを押したらアプリが落ちた [plan](docs/plans/end-session-crash.md)
- [ ] 会話終了後のフィードバックの文章が途中で途切れる [plan](docs/plans/feedback-truncated.md)
