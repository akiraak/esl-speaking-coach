# TODO

- [ ] 安い中国系AIモデルを調査 [plan](docs/plans/cheap-chinese-ai-models.md)
  - [x] Phase 1: 机上調査（モデル・料金・API 仕様の一覧化）
  - [x] Phase 2: API キー収集（Alibaba Model Studio + OpenRouter のアカウント作成・`.secrets/` 配置・疎通確認）
  - [x] Phase 3: 実測比較（品質・レイテンシ）
  - [ ] Phase 4: 判断とまとめ（コスト再計算・経路ごとの採否）
  - [ ] Phase 5: 生成品質の厳密チェック（Phase 4 の後に、Phase 3 より厳密な品質評価を実施。ケース数・実行回数を増やし判定の信頼度を上げる）

## 不具合

- [ ] 会話終了ボタンを押したらアプリが落ちた [plan](docs/plans/end-session-crash.md)
- [ ] 会話終了後のフィードバックの文章が途中で途切れる [plan](docs/plans/feedback-truncated.md)
