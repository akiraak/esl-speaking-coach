# TODO

- [ ] Qwen TTS instruct 変種（`qwen3-tts-instruct-flash-realtime`）の単価を Model Studio コンソールか初回請求で確認し、`AIPricing` / `docs/specs/ai-cost-map.md` の暫定値（base と同額 $0.13/1 万字）を確定する

- [ ] チャット欄英語の再読み上げ

- 料金画面の修正
  - 種別内訳に使用しているモデルと単価を表示。代わりに単価表を削除
  - 種別内訳の料金は今月分と今月全体料金との割合を%表示

## 不具合

- [ ] 会話終了ボタンを押したらアプリが落ちた [plan](docs/plans/end-session-crash.md)
- [ ] 会話終了後のフィードバックの文章が途中で途切れる [plan](docs/plans/feedback-truncated.md)
