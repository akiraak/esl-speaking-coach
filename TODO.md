# TODO

- [ ] 音声入力で周囲の雑音や声からセリフを拾ってしまうのの改善 [plan](docs/plans/noise-input-rejection.md)
  - [ ] Phase 0: セグメント診断ログ（管理画面のみ）を入れて実機で実測し閾値の初期値を決める
  - [ ] Phase 1: サーバ VAD の `threshold` / `prefix_padding_ms` を明示指定
  - [ ] Phase 2: logprobs 信頼度ゲート（`include` 追加 + スコア算出 + 破棄判定）
  - [ ] Phase 3: クライアント側レベルゲート（ノイズフロア追従 + SNR 判定）
  - [ ] Phase 4: transcript 内容フィルタの拡張（定型幻覚・記号のみ・非 ASCII。薄く）
  - [ ] Phase 5: barge-in を「確からしい発話」に限定（猶予判定）
  - [ ] Phase 6: 実機で総合確認 → 決定した閾値を conversation-design.md へ反映
