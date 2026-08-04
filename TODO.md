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

- [ ] 音声入力の音量・時間のしきい値を管理画面で調整可能にする [plan](docs/plans/voice-input-tuning-in-admin.md)
  - 一式 7 項目（音量 3 / 時間 4）・反映は次のセッションから・直近セグメントの実測を並べる
  - [x] Phase 1: `VoiceInputSettingsStore` と 7 項目の定義（範囲・刻み・既定は保存しない）
  - [x] Phase 2: 管理画面「音声入力」の画面とルートへの追加
  - [x] Phase 3: セッションへの反映（`clientEndpointer` / `levelGate`）と診断ログ
  - [x] Phase 4: 直近セグメントの実測表示（`.segmentMeasured` イベント + リングバッファ）
  - [x] Phase 5: 環境プリセット 3 種（静かな部屋 / 生活音のある部屋 / 外・カフェ）
  - [ ] 実機確認: 閾値を上げて誤検知が減るか / 発話の頭切れが出ないか

- [ ] iPhoneのボリュームを下げても読み上げ音量が下がらない

## 不具合

- [ ] 声を出していないのに入力終了 → 開始のジングルが鳴る [plan](docs/plans/empty-segment-no-cue.md)
  - ノイズで VAD だけ発火し、確定テキストが空だった経路。空と分かったターンは無音で通す
  - [ ] 実機確認: 物音で鳴らないこと / 通常発話で終了ジングルの遅れが不自然でないこと
- [ ] 会話終了ボタンを押したらアプリが落ちた [plan](docs/plans/end-session-crash.md)
- [ ] 会話終了後のフィードバックの文章が途中で途切れる [plan](docs/plans/feedback-truncated.md)
- [ ] 読み上げが途中で止まることが起きるかチェック
