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

### 実機データが無いとき（合成 fixture）

`synthetic/` に、実機の書き出しが無くても Phase 2 / 3 を回せる**合成セッション**がある
（docs/plans/model-comparison-sonnet5-haiku45.md）。`SessionExporter.Export` と同じ形なので、
`export.json` として置けば上の手順 3 以降がそのまま通る。

```
python3 synthetic/build_export.py            # → synthetic/export.json
cp synthetic/export.json fixtures/export.json
python3 synthetic/extract_prompts.py fixtures # system prompt 6 本を Swift から直接パース
node build_fixtures.mjs
node synthetic/build_cases_synth.mjs         # → fixtures/cases-synth.json
node synthetic/run_gen_synth.mjs      && node synthetic/report_gen_synth.mjs
node synthetic/run_replay_synth.mjs
node synthetic/judge_synth.mjs               # opus-5 ブラインド A/B（単発）
node synthetic/judge_replay_synth.mjs        # 同（マルチターン再生）
node synthetic/run_feedback_synth.mjs && node synthetic/report_feedback_synth.mjs
node synthetic/run_memory_synth.mjs
```

- **実会話ではない**。評価ケースが狙う状況（STT ノイズ・一語返答・日英混在・語学質問・
  明示的な別れ・曖昧な終わり）と、日本人学習者に典型的な誤り（冠詞落ち・時制・和製英語）を
  意図的に仕込んである。実会話を含まないので**リポジトリに置ける**
- `extract_prompts.py` は Swift の複数行文字列を直接パースする。`swiftc` でのビルドは
  依存が芋づる式に増えて詰まるため（`main.swift` 方式で抽出できるのは依存の少ない 2 本だけ）。
  swiftc で抽出できる 3 本と一致することを毎回検算している
- 実機データが用意できたら `fixtures/export.json` を差し替え、`build_cases_synth.mjs` の
  セッション参照（タイトル）を実データのものに変えれば同じケース定義で回し直せる

### トピック生成の比較（fixture 不要・単体で動く）

`run_topic.mjs` / `report_topic.mjs` は実会話の fixture を使わず、割り当てパターンを
スクリプト内に固定して比較する（docs/plans/model-comparison-sonnet5-haiku45.md Phase 1）。
`fixtures/system-topic.txt` だけ用意すれば動く:

```
swiftc -O -o dump \
  EslSpeakingCoach/Claude/{TopicSuggestionClient,CoachSystemPrompt}.swift \
  EslSpeakingCoach/Conversation/TopicCatalog.swift \
  EslSpeakingCoach/Usage/AIUsage.swift main.swift   # main.swift で systemPrompt を書き出す
node run_topic.mjs && node report_topic.mjs
```

機械チェック（スキーマ適合・genre_id の echo・文字数・重複）に加えて、
**モデル別の実額**（usage × 単価）を集計する。

## 前提

- `.secrets/anthropic-api-key`（必須）、候補モデルに応じて `dashscope-api-key` /
  `openrouter-api-key` / `gemini-api-key`（無いキーは `null` になるだけで他の比較は動く）
- 候補モデルの追加・変更は各 run_*.mjs の `providers` 配列を編集する
- プロバイダのアダプタは `lib.mjs`: `anthropicStream`（Anthropic 本家 / 互換）、
  `openaiStream`（DashScope / OpenRouter）、`geminiStream`（Gemini API。Gemma 4 の評価用。
  `systemInstruction` + `responseJsonSchema`。effort / thinking / キャッシュの概念が無い）
- 合否基準と Phase 5 での実測結果は docs/plans/archive/cheap-chinese-ai-models.md の
  「Phase 5 具体化 / 実施記録」を参照
