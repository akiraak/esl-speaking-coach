// Phase 5 Step 2/4: 単発ターン生成 (conversation 11 + wordquiz 4 ケース × 3 モデル × 5 生成)
// リクエスト形は本番同一 (effort low / max_tokens 1024 / stream / cache_control。qwen は thinking disabled)
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { keys, anthropicStream, sleep } from "./lib.mjs";

const DIR = new URL(".", import.meta.url).pathname;
const CASES = JSON.parse(readFileSync(`${DIR}fixtures/cases5.json`, "utf8"));
const SYSTEMS = {
  conversation: readFileSync(`${DIR}fixtures/system-conversation.txt`, "utf8"),
  word: readFileSync(`${DIR}fixtures/system-word.txt`, "utf8"),
  quiz: readFileSync(`${DIR}fixtures/system-quiz.txt`, "utf8"),
};
const GENS = 5;
const OUT = `${DIR}results5-gen.json`;

const providers = [
  {
    id: "sonnet-5",
    gen: (system, messages) => anthropicStream({
      model: "claude-sonnet-5", system, messages, effort: "low", maxTokens: 1024,
    }),
  },
  {
    id: "qwen3.7-plus",
    gen: (system, messages) => anthropicStream({
      endpoint: "https://dashscope-intl.aliyuncs.com/apps/anthropic/v1/messages",
      apiKey: keys.dashscope, model: "qwen3.7-plus", system, messages,
      effort: "low", maxTokens: 1024, thinking: { type: "disabled" },
    }),
  },
  {
    id: "qwen3.7-flash",
    gen: (system, messages) => anthropicStream({
      endpoint: "https://dashscope-intl.aliyuncs.com/apps/anthropic/v1/messages",
      apiKey: keys.dashscope, model: "qwen3.7-flash", system, messages,
      effort: "low", maxTokens: 1024, thinking: { type: "disabled" },
    }),
  },
];

const allCases = [...CASES.conversation, ...CASES.wordquiz];
const results = existsSync(OUT) ? JSON.parse(readFileSync(OUT, "utf8")) : {};
const save = () => writeFileSync(OUT, JSON.stringify(results, null, 2));

async function runProvider(p) {
  results[p.id] ??= {};
  for (const c of allCases) {
    results[p.id][c.id] ??= [];
    const runs = results[p.id][c.id];
    if (runs.filter((r) => !r.error).length >= GENS) continue; // 再開用スキップ
    const system = SYSTEMS[c.system];
    while (runs.filter((r) => !r.error).length < GENS) {
      try {
        const r = await p.gen(system, c.messages);
        runs.push({
          text: r.text, stopReason: r.stopReason, ttft: r.ttft,
          firstSentence: r.firstSentence, total: r.total,
          cacheRead: r.usage?.cache_read_input_tokens ?? null,
        });
        console.log(`[${p.id} ${c.id} #${runs.length}] ttft=${Math.round(r.ttft)}ms len=${r.text.length}`);
      } catch (e) {
        runs.push({ error: String(e.message).slice(0, 300) });
        console.log(`[${p.id} ${c.id}] ERROR: ${String(e.message).slice(0, 200)}`);
        if (runs.filter((r) => r.error).length >= 3) break; // 失敗し続けたら諦めて次へ
      }
      save();
      await sleep(250);
    }
  }
  console.log(`===== ${p.id} done`);
}

await Promise.all(providers.map(runProvider));
save();
console.log("saved results5-gen.json");
