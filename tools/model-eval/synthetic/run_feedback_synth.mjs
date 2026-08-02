// 合成 transcript でのフィードバック生成比較（Phase 3）。
// 本番 SessionFeedbackClient と同じ system prompt / user メッセージ / スキーマ。
// sonnet-5 のみ effort: high（haiku は 400、Gemma には概念が無いので送らない）。
// Gemma は会話ターンでは失格だが、こちらは structured outputs 経路なので対象に含める。
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { keys, anthropicStream, geminiStream, sleep } from "./lib.mjs";

const DIR = new URL(".", import.meta.url).pathname;
const CASES = JSON.parse(readFileSync(`${DIR}fixtures/cases-synth.json`, "utf8"));
const SYSTEM = readFileSync(`${DIR}fixtures/system-feedback.txt`, "utf8");
const OUT = `${DIR}results-feedback-synth.json`;
const GENS = 3;

const correction = {
  type: "object",
  properties: {
    original: { type: "string" },
    improved: { type: "string" },
    note: { type: "string" },
  },
  required: ["original", "improved", "note"],
  additionalProperties: false,
};
const tryPhrase = {
  type: "object",
  properties: { phrase: { type: "string" }, meaning: { type: "string" } },
  required: ["phrase", "meaning"],
  additionalProperties: false,
};
const SCHEMA = {
  type: "object",
  properties: {
    summary: { type: "string" },
    corrections: { type: "array", items: correction },
    try_phrases: { type: "array", items: tryPhrase },
  },
  required: ["summary", "corrections", "try_phrases"],
  additionalProperties: false,
};

// kind ごとのラベル（SessionKind.feedbackTopicLabel 相当）
const LABEL = { conversation: "Topic", word: "Word", quiz: "Quiz words" };
const userMessage = (c) => `${LABEL[c.kind]}: ${c.topic}\n\nTranscript:\n${c.transcript}`;

const providers = [
  {
    id: "sonnet-5",
    gen: (c) => anthropicStream({
      model: "claude-sonnet-5", system: SYSTEM,
      messages: [{ role: "user", content: userMessage(c) }],
      effort: "high", maxTokens: 16000,
      format: { type: "json_schema", schema: SCHEMA },
    }),
  },
  {
    id: "haiku-4-5",
    gen: (c) => anthropicStream({
      model: "claude-haiku-4-5", system: SYSTEM,
      messages: [{ role: "user", content: userMessage(c) }],
      maxTokens: 16000,
      format: { type: "json_schema", schema: SCHEMA },
    }),
  },
  {
    id: "gemma-4-31b-it",
    gen: (c) => geminiStream({
      model: "gemma-4-31b-it", system: SYSTEM,
      messages: [{ role: "user", content: userMessage(c) }],
      maxTokens: 8192, schema: SCHEMA,
    }),
    delayMs: 4000,
  },
];

const results = existsSync(OUT) ? JSON.parse(readFileSync(OUT, "utf8")) : {};

for (const provider of providers) {
  if (provider.id === "gemma-4-31b-it" ? !keys.gemini : !keys.anthropic) continue;
  results[provider.id] ??= {};
  for (const c of CASES.feedback) {
    results[provider.id][c.id] ??= [];
    while (results[provider.id][c.id].length < GENS) {
      const index = results[provider.id][c.id].length;
      process.stdout.write(`${provider.id} ${c.id}(${c.topic})#${index} ... `);
      try {
        const r = await provider.gen(c);
        results[provider.id][c.id].push({
          text: r.text, stopReason: r.stopReason, usage: r.usage, total: r.total,
        });
        console.log(`ok (${Math.round(r.total)}ms, ${r.text.length} chars, stop=${r.stopReason})`);
      } catch (error) {
        results[provider.id][c.id].push({ error: String(error).slice(0, 300) });
        console.log(`ERROR ${String(error).slice(0, 120)}`);
      }
      writeFileSync(OUT, JSON.stringify(results, null, 2));
      await sleep(provider.delayMs ?? 500);
    }
  }
}
console.log(`\n→ ${OUT}`);
