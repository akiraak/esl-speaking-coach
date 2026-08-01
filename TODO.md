# TODO

- [ ] Qwen TTS instruct 変種（`qwen3-tts-instruct-flash-realtime`）の単価を Model Studio コンソールか初回請求で確認し、`AIPricing` / `docs/specs/ai-cost-map.md` の暫定値（base と同額 $0.13/1 万字）を確定する

- [ ] ファイルを保存して容量を圧迫していないかチェック [plan](docs/plans/chat-storage-audit.md)
  - [ ] Phase 1: 管理画面にストレージ内訳を表示して実測（1 セッションあたりの増分を見積もる）
  - [ ] Phase 2: 実測に基づく判断とエクスポート残骸の掃除
- [ ] チャット欄英語の再読み上げ（直前 1 セッションは保存音声・無ければ再生成） [plan](docs/plans/utterance-replay.md)
  - [x] Phase 1: TTS クライアント生成のファクトリ化 + UtteranceReplayer（再生成経路のみ）
  - [x] Phase 2: 音声キャッシュ（保存・.part 完結・開始時 / 起動時の削除・ファイル優先再生）
  - [x] Phase 3: タップ導線・🔊 表示・停止 / 切り替え・usage 記録（シミュレータで保存 → ファイル再生 / 再生成 / 開始時削除まで確認済み）
  - [ ] 実機確認（イヤフォン / Bluetooth / 内蔵スピーカーの出力経路・再読み上げ直後のセッション開始・長めのセッションのキャッシュ実サイズ）
- [ ] トピック生成をhaiku4.5に変更

## 不具合

- [ ] 会話終了ボタンを押したらアプリが落ちた [plan](docs/plans/end-session-crash.md)
- [ ] 会話終了後のフィードバックの文章が途中で途切れる [plan](docs/plans/feedback-truncated.md)
