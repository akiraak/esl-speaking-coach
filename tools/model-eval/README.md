# model-eval — 会話 / フィードバック LLM の実データ評価ハーネス

安い中国系 AI モデル調査の Phase 5（docs/plans/archive/cheap-chinese-ai-models.md）で使った
評価一式。新しい候補モデルが出たときに同じ方法で再評価できるよう、スクリプトだけ保存してある
（fixture・生成結果は実会話を含むためリポジトリに入れない。作業ディレクトリで生成する）。

## 使い方（作業ディレクトリを作って実行する）

各スクリプトは自分と同じ場所の `fixtures/` を読み書きするので、このディレクトリごと
リポジトリ外の作業場所（例: `/tmp/model-eval-work/`）へコピーしてから実行する。


1. **実データ取得**: DEBUG ビルドの管理画面 → 左上の書き出しボタン → AirDrop で
   `esl-sessions-*.json` を Mac へ。`fixtures/export.json` として置く
2. **system prompt 抽出**: `main.swift` を参照。
   `swiftc -o dump EslSpeakingCoach/Claude/{WordCoach,QuizCoach}SystemPrompt.swift main.swift`
   の要領で 4 本（conversation / word / quiz / feedback）を `fixtures/system-*.txt` へ
3. `node build_fixtures.mjs` — API 形式履歴の再構築（本番 `ChatRoomStore.rebuildHistory` /
   `SessionOpeningMessage` と同一規則）→ `fixtures/sessions.json`
4. `node build_cases.mjs` — 評価ケース組み立て → `fixtures/cases5.json`。
   **セッションのタイトル・切り出し位置を実データに合わせて調整すること**（エクスポート内容依存）
5. `node run_gen5.mjs` / `node run_replay5.mjs` / `node run_feedback5.mjs` — 生成
   （逐次保存・再実行で続きから）
6. `node report5.mjs` — 機械チェック集計（タグ・発話数・[end]・CJK 混入・最終行の質問）
7. `node judge5.mjs` — opus-5 ブラインド A/B（順序入替 2 回・不一致 tie）と集計

## 前提

- `.secrets/anthropic-api-key`（必須）、候補モデルに応じて `dashscope-api-key` /
  `openrouter-api-key`
- 候補モデルの追加・変更は各 run_*.mjs の `providers` 配列を編集する
- 合否基準と Phase 5 での実測結果は docs/plans/archive/cheap-chinese-ai-models.md の
  「Phase 5 具体化 / 実施記録」を参照
