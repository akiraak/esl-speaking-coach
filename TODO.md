# TODO

- トピックが単調なのを改善する [plan](docs/plans/topic-variety.md)
  - [ ] Phase 1: ジャンル / 話し方カタログと、直近ジャンルを除外するサンプラー（RNG 注入可能）
  - [ ] Phase 2: system prompt 書き換え + リクエストへの割り当て注入（スキーマに genre 追加）
  - [ ] Phase 3: `ChatSessionRecord.topicGenre` を additive 追加し、直近ジャンルを復元してサンプラーへ
  - [ ] Phase 4: シミュレータ確認 + `conversation-design.md` 同期 + 後片付け
