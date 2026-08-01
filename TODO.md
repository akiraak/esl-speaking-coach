# TODO

- [ ] Qwen TTS instruct 変種（`qwen3-tts-instruct-flash-realtime`）の単価を Model Studio コンソールか初回請求で確認し、`AIPricing` / `docs/specs/ai-cost-map.md` の暫定値（base と同額 $0.13/1 万字）を確定する

- [ ] 本番単語帳の誤登録「makes sense」を admin（esl.chobi.me/admin）から削除（手動。単語登録機能の実機確認時に入ったもの。削除済みならこの項目を消すだけでよい）
- [ ] ファイルを保存して容量を圧迫していないかチェック [plan](docs/plans/chat-storage-audit.md)
  - [ ] Phase 1: 管理画面にストレージ内訳を表示して実測（1 セッションあたりの増分を見積もる）
  - [ ] Phase 2: 実測に基づく判断とエクスポート残骸の掃除
- [ ] チャット欄英語の再読み上げ（直前 1 セッションは保存音声・無ければ再生成） [plan](docs/plans/utterance-replay.md)
  - [ ] Phase 1: TTS クライアント生成のファクトリ化 + UtteranceReplayer（再生成経路のみ）
  - [ ] Phase 2: 音声キャッシュ（保存・.part 完結・開始時 / 起動時の削除・ファイル優先再生）
  - [ ] Phase 3: タップ導線・🔊 表示・停止 / 切り替え・usage 記録 → 実機確認
- [ ] トピック生成をhaiku4.5に変更

## 不具合

- [ ] DEBUG ビルドの TTS 既定が Gemini のまま: `ChatRoomStore.launchSession` の `ttsProviderOverride ?? .gemini`（ChatRoomStore.swift:682）が Qwen 切替（7c95fdb）後も残っており、`-tts-provider` 未指定の実機・シミュレータ（= 普段の使い方）では Configuration 既定の qwen が gemini に上書きされる
- [ ] 会話終了ボタンを押したらアプリが落ちた [plan](docs/plans/end-session-crash.md)
- [ ] 会話終了後のフィードバックの文章が途中で途切れる [plan](docs/plans/feedback-truncated.md)
