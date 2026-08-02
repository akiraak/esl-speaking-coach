// トピック生成の 3 モデル比較（docs/plans/model-comparison-sonnet5-haiku45.md Phase 1）
// 本番 TopicSuggestionClient と同じ system prompt / user メッセージ / スキーマで生成し、
// 機械チェック（スキーマ適合・文字数・genre_id の echo・重複）と usage を集計する。
//
// 前提: fixtures/system-topic.txt（main.swift で TopicSuggestionClient.systemPrompt を書き出したもの）
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { keys, anthropicStream, geminiStream, sleep } from "./lib.mjs";

const DIR = new URL(".", import.meta.url).pathname;
const SYSTEM = readFileSync(`${DIR}fixtures/system-topic.txt`, "utf8");
const OUT = `${DIR}results-topic.json`;
const GENS = 4; // 割り当てパターンごとの生成回数

// 本番の TopicAssignmentSampler が引く形（genre × angle × difficulty）を固定パターンにしたもの。
// 3 件セット（初回起動 / 🔄）を 5 パターン。同一入力を全モデルへ投げて比較する。
const CASES = [
  {
    id: "set-a",
    recent: ["スマホ依存どう思う?", "観るスポーツ派?やる派?", "もしも仕事を変えたら"],
    assignments: [
      { genre_id: "food", genre: "food and eating", angle: "recall a past experience and tell it as a story", difficulty: "easy" },
      { genre_id: "technology", genre: "technology, gadgets and apps", angle: "compare two options and pick one", difficulty: "normal" },
      { genre_id: "childhood", genre: "childhood memories", angle: "imagine a hypothetical situation", difficulty: "slightly challenging" },
    ],
  },
  {
    id: "set-b",
    recent: ["朝ごはん何食べる?", "AIが友達になる日"],
    assignments: [
      { genre_id: "neighborhood", genre: "your town and neighborhood", angle: "describe something in front of you in detail", difficulty: "easy" },
      { genre_id: "mishaps", genre: "mishaps and embarrassing moments", angle: "recall a past experience and tell it as a story", difficulty: "normal" },
      { genre_id: "aspirations", genre: "things you admire or want to try", angle: "make a plan for something upcoming", difficulty: "slightly challenging" },
    ],
  },
  {
    id: "set-c",
    recent: [],
    assignments: [
      { genre_id: "housework", genre: "housework and daily chores", angle: "explain how something is done, step by step", difficulty: "easy" },
      { genre_id: "money", genre: "how you spend money", angle: "state an opinion and agree or disagree", difficulty: "normal" },
      { genre_id: "what-if", genre: "imaginary what-if situations", angle: "imagine a hypothetical situation", difficulty: "slightly challenging" },
    ],
  },
  {
    id: "set-d",
    recent: ["好きなゲームのやり方", "苦手な家事ある?", "最近買ってよかったもの"],
    assignments: [
      { genre_id: "sleep", genre: "sleep, mornings and nights", angle: "compare two options and pick one", difficulty: "easy" },
      { genre_id: "language", genre: "learning languages and words", angle: "teach or recommend something to a friend", difficulty: "normal" },
      { genre_id: "small-pride", genre: "something you are quietly proud of", angle: "recall a past experience and tell it as a story", difficulty: "slightly challenging" },
    ],
  },
  {
    // 1 件だけの補充（セッション終了後）。件数指示に従えるかを見る
    id: "refill-single",
    recent: ["ペットとの暮らし", "雨の日の過ごし方"],
    assignments: [
      { genre_id: "celebrations", genre: "holidays and celebrations", angle: "make a plan for something upcoming", difficulty: "normal" },
    ],
  },
];

const SCHEMA = {
  type: "object",
  properties: {
    topics: {
      type: "array",
      items: {
        type: "object",
        properties: { title: { type: "string" }, hook: { type: "string" }, genre: { type: "string" } },
        required: ["title", "hook", "genre"],
        additionalProperties: false,
      },
    },
  },
  required: ["topics"],
  additionalProperties: false,
};

// 本番 TopicSuggestionClient.makeRequestBody と同じ組み立て
const userMessage = (c) => {
  const recent = c.recent.length ? c.recent.join(", ") : "(none)";
  const lines = c.assignments
    .map((a, i) => `${i + 1}. genre_id: ${a.genre_id} | genre: ${a.genre} | angle: ${a.angle} | difficulty: ${a.difficulty}`)
    .join("\n");
  return `Recent topics: ${recent}\n\nAssignments:\n${lines}`;
};

const providers = [
  {
    id: "sonnet-5",
    gen: (c) => anthropicStream({
      model: "claude-sonnet-5", system: SYSTEM,
      messages: [{ role: "user", content: userMessage(c) }],
      effort: "low", maxTokens: 1024,
      format: { type: "json_schema", schema: SCHEMA },
    }),
  },
  {
    // haiku は output_config.effort が 400 になるため送らない（プラン「等価比較の設計」）
    id: "haiku-4-5",
    gen: (c) => anthropicStream({
      model: "claude-haiku-4-5", system: SYSTEM,
      messages: [{ role: "user", content: userMessage(c) }],
      maxTokens: 1024,
      format: { type: "json_schema", schema: SCHEMA },
    }),
  },
  {
    id: "gemma-4-31b-it",
    gen: (c) => geminiStream({
      model: "gemma-4-31b-it", system: SYSTEM,
      messages: [{ role: "user", content: userMessage(c) }],
      maxTokens: 1024, schema: SCHEMA,
    }),
    // Gemini API の無料枠はレート制限があるので間隔を空ける
    delayMs: 4000,
  },
];

const results = existsSync(OUT) ? JSON.parse(readFileSync(OUT, "utf8")) : {};

for (const provider of providers) {
  if (provider.id !== "gemma-4-31b-it" && !keys.anthropic) continue;
  if (provider.id === "gemma-4-31b-it" && !keys.gemini) continue;
  results[provider.id] ??= {};
  for (const c of CASES) {
    results[provider.id][c.id] ??= [];
    while (results[provider.id][c.id].length < GENS) {
      const index = results[provider.id][c.id].length;
      process.stdout.write(`${provider.id} ${c.id}#${index} ... `);
      try {
        const r = await provider.gen(c);
        results[provider.id][c.id].push({
          text: r.text, stopReason: r.stopReason, usage: r.usage, total: r.total,
        });
        console.log(`ok (${Math.round(r.total)}ms)`);
      } catch (error) {
        results[provider.id][c.id].push({ error: String(error).slice(0, 300) });
        console.log(`ERROR ${String(error).slice(0, 120)}`);
      }
      writeFileSync(OUT, JSON.stringify(results, null, 2)); // 逐次保存・再実行で続きから
      await sleep(provider.delayMs ?? 500);
    }
  }
}

console.log(`\n→ ${OUT}`);
