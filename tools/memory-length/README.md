# memory-length — 記憶ノートが予算内に収まるかの実測

`MemoryUpdateClient` の生成が、記憶ノートを行数予算の中に収めるかを実 API で測る
（[memory-note-length.md](../../docs/plans/archive/memory-note-length.md)）。
プロンプトを触ったら回して、太ったノートが縮むか・健全なノートを削りすぎないかを見る。

```bash
node tools/memory-length/run.mjs both      # 2 ケースとも
node tools/memory-length/run.mjs bloated   # 上限を大きく超えたノート（不具合の再現）
node tools/memory-length/run.mjs small     # 普段の 1 セッションぶん（過剰圧縮の回帰）
```

- system prompt は **Swift の `MemoryUpdateClient.systemPrompt` から毎回抽出する**
  （`tools/model-eval/synthetic/extract_prompts.py` を流用）。スクリプト側にプロンプトの写しを
  持たないので、Swift を直したら再実行するだけでよい
- モデル・effort・`max_tokens`・schema は `makeRequestBody` と同じにしてある。ずらすと測る意味が無い
- **生成物は全文を標準出力へ出す。** 語数だけ見ていると、事実が壊れた・過剰に削られたのに
  「予算内」で通ってしまう
- `.secrets/anthropic-api-key` を読むので課金される（1 ケース ≈ 出力 600〜1,400 トークン）

## fixture

| ファイル | 中身 |
| --- | --- |
| `learner-bloated.txt` | 605 語 / 42 行。多数のセッションを重ねて太った学習者ノートを模したもの |
| `learner-small.txt` | 130 語 / 11 行。数セッションぶんの健全なノート |

キャラノートと transcript は `run.mjs` に直接書いてある（短いので fixture にしていない）。

## 実測（2026-08-05・claude-sonnet-5）

| プロンプト | bloated（入力 605 語） | small（入力 130 語） |
| --- | --- | --- |
| 語数だけで指示（旧） | **622 語** ← 増える | — |
| 行数で予算（新） | 270 / 349 / 357 語（3 回） | 147 語 |
