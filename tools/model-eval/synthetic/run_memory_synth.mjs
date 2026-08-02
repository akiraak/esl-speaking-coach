// 記憶ノート更新の比較（Phase 3 の後半）。
// 本番 MemoryUpdateClient と同じ system prompt / user メッセージ / スキーマ。
// sonnet-5 のみ effort: medium（haiku は 400、Gemma には概念が無いので送らない）。
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { keys, anthropicStream, geminiStream, sleep } from "./lib.mjs";

const DIR = new URL(".", import.meta.url).pathname;
const CASES = JSON.parse(readFileSync(`${DIR}fixtures/cases-synth.json`, "utf8"));
const SYSTEM = readFileSync(`${DIR}fixtures/system-memory.txt`, "utf8");
const OUT = `${DIR}results-memory-synth.json`;
const GENS = 3;

const SCHEMA = {
  type: "object",
  properties: { memory: { type: "string" } },
  required: ["memory"],
  additionalProperties: false,
};

// 前回ノート → セッション → 更新後ノート、の流れを見たいので 2 パターン用意する
const PREVIOUS = {
  "with-previous": CASES.memoryNote,
  "from-empty": "",
};

const userMessage = (previous, c) =>
  `Previous memory note:\n${previous.trim() || "(none)"}\n\n`
  + `Topic of the session that just ended: ${c.topic}\n\nTranscript:\n${c.transcript}`;

const providers = [
  {
    id: "sonnet-5",
    gen: (previous, c) => anthropicStream({
      model: "claude-sonnet-5", system: SYSTEM,
      messages: [{ role: "user", content: userMessage(previous, c) }],
      effort: "medium", maxTokens: 2000,
      format: { type: "json_schema", schema: SCHEMA },
    }),
  },
  {
    id: "haiku-4-5",
    gen: (previous, c) => anthropicStream({
      model: "claude-haiku-4-5", system: SYSTEM,
      messages: [{ role: "user", content: userMessage(previous, c) }],
      maxTokens: 2000,
      format: { type: "json_schema", schema: SCHEMA },
    }),
  },
  {
    id: "gemma-4-31b-it",
    gen: (previous, c) => geminiStream({
      model: "gemma-4-31b-it", system: SYSTEM,
      messages: [{ role: "user", content: userMessage(previous, c) }],
      maxTokens: 2000, schema: SCHEMA,
    }),
    delayMs: 4000,
  },
];

// 会話 2 本 × 前回ノート有無 2 パターン
const targets = [];
for (const c of CASES.feedback.filter((x) => x.kind === "conversation").slice(0, 2)) {
  for (const [prevKey, previous] of Object.entries(PREVIOUS)) {
    targets.push({ id: `${c.id}-${prevKey}`, previous, case: c });
  }
}

const results = existsSync(OUT) ? JSON.parse(readFileSync(OUT, "utf8")) : {};

for (const provider of providers) {
  if (provider.id === "gemma-4-31b-it" ? !keys.gemini : !keys.anthropic) continue;
  results[provider.id] ??= {};
  for (const t of targets) {
    results[provider.id][t.id] ??= [];
    while (results[provider.id][t.id].length < GENS) {
      const index = results[provider.id][t.id].length;
      process.stdout.write(`${provider.id} ${t.id}#${index} ... `);
      try {
        const r = await provider.gen(t.previous, t.case);
        results[provider.id][t.id].push({
          text: r.text, stopReason: r.stopReason, usage: r.usage, total: r.total,
          previous: t.previous, topic: t.case.topic,
        });
        console.log(`ok (${r.text.length} chars)`);
      } catch (error) {
        results[provider.id][t.id].push({ error: String(error).slice(0, 300) });
        console.log(`ERROR ${String(error).slice(0, 120)}`);
      }
      writeFileSync(OUT, JSON.stringify(results, null, 2));
      await sleep(provider.delayMs ?? 500);
    }
  }
}
console.log(`\n→ ${OUT}`);
