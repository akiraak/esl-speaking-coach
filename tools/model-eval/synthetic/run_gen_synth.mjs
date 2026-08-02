// 合成ケースでの単発ターン生成（会話 10 + 単語 2 ケース × 3 モデル × 3 生成）
// リクエスト形は本番同一（stream / max_tokens 1024 / system に cache_control）。
// sonnet-5 のみ effort: low。haiku は effort 非対応、Gemma には概念が無いので送らない。
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { keys, anthropicStream, geminiStream, sleep } from "./lib.mjs";

const DIR = new URL(".", import.meta.url).pathname;
const CASES = JSON.parse(readFileSync(`${DIR}fixtures/cases-synth.json`, "utf8"));
const SYSTEMS = {
  conversation: readFileSync(`${DIR}fixtures/system-conversation.txt`, "utf8"),
  word: readFileSync(`${DIR}fixtures/system-word.txt`, "utf8"),
};
const GENS = 3;
const OUT = `${DIR}results-gen-synth.json`;

const providers = [
  {
    id: "sonnet-5",
    gen: (system, messages) => anthropicStream({
      model: "claude-sonnet-5", system, messages, effort: "low", maxTokens: 1024,
    }),
  },
  {
    id: "haiku-4-5",
    gen: (system, messages) => anthropicStream({
      model: "claude-haiku-4-5", system, messages, maxTokens: 1024,
    }),
  },
  {
    id: "gemma-4-31b-it",
    gen: (system, messages) => geminiStream({
      model: "gemma-4-31b-it", system, messages, maxTokens: 1024,
    }),
    delayMs: 4000,
  },
];

const allCases = [...CASES.conversation, ...CASES.wordquiz];
const results = existsSync(OUT) ? JSON.parse(readFileSync(OUT, "utf8")) : {};

for (const provider of providers) {
  if (provider.id === "gemma-4-31b-it" ? !keys.gemini : !keys.anthropic) continue;
  results[provider.id] ??= {};
  for (const c of allCases) {
    const system = SYSTEMS[c.system ?? "conversation"];
    results[provider.id][c.id] ??= [];
    while (results[provider.id][c.id].length < GENS) {
      const index = results[provider.id][c.id].length;
      process.stdout.write(`${provider.id} ${c.id}#${index} ... `);
      try {
        const r = await provider.gen(system, c.messages);
        results[provider.id][c.id].push({
          text: r.text, stopReason: r.stopReason, usage: r.usage, total: r.total,
        });
        console.log(`ok (${Math.round(r.total)}ms, ${r.text.split("\n").filter(Boolean).length} lines)`);
      } catch (error) {
        results[provider.id][c.id].push({ error: String(error).slice(0, 300) });
        console.log(`ERROR ${String(error).slice(0, 120)}`);
      }
      writeFileSync(OUT, JSON.stringify(results, null, 2));
      await sleep(provider.delayMs ?? 400);
    }
  }
}
console.log(`\n→ ${OUT}`);
