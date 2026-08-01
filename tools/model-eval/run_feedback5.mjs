// Phase 5 Step 4: フィードバック生成 (実 transcript 4 本 × 3 モデル × 3 生成)
// 方式は Phase 3 で確定した各モデルの採用形:
// - sonnet-5: 本番同一 (json_schema / effort high / max_tokens 16000)
// - qwen3.7-plus: Anthropic 互換 + 同一形 + thinking disabled
// - deepseek-v4-flash: OpenRouter 米系固定 + response_format json_schema + reasoning 抑制
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { keys, anthropicStream, openaiStream, sleep } from "./lib.mjs";

const DIR = new URL(".", import.meta.url).pathname;
const SYSTEM = readFileSync(`${DIR}fixtures/system-feedback.txt`, "utf8");
const CASES = JSON.parse(readFileSync(`${DIR}fixtures/cases5.json`, "utf8")).feedback;
const GENS = 3;
const OUT = `${DIR}results5-feedback.json`;

const schema = {
  type: "object",
  properties: {
    summary: { type: "string" },
    corrections: {
      type: "array",
      items: {
        type: "object",
        properties: { original: { type: "string" }, improved: { type: "string" }, note: { type: "string" } },
        required: ["original", "improved", "note"], additionalProperties: false,
      },
    },
    try_phrases: {
      type: "array",
      items: {
        type: "object",
        properties: { phrase: { type: "string" }, meaning: { type: "string" } },
        required: ["phrase", "meaning"], additionalProperties: false,
      },
    },
  },
  required: ["summary", "corrections", "try_phrases"], additionalProperties: false,
};

const userContent = (c) => `Topic: ${c.topic}\n\nTranscript:\n${c.transcript}`;

export function validate(text) {
  let obj;
  try { obj = JSON.parse(text); } catch { return { ok: false, why: "JSON parse error" }; }
  const why = [];
  if (typeof obj.summary !== "string") why.push("summary missing");
  if (!Array.isArray(obj.corrections)) why.push("corrections missing");
  else for (const x of obj.corrections)
    if (typeof x.original !== "string" || typeof x.improved !== "string" || typeof x.note !== "string") { why.push("corrections item malformed"); break; }
  if (!Array.isArray(obj.try_phrases)) why.push("try_phrases missing");
  else for (const x of obj.try_phrases)
    if (typeof x.phrase !== "string" || typeof x.meaning !== "string") { why.push("try_phrases item malformed"); break; }
  const extra = Object.keys(obj).filter((k) => !["summary", "corrections", "try_phrases"].includes(k));
  if (extra.length) why.push(`extra keys: ${extra.join(",")}`);
  return { ok: why.length === 0, why: why.join("; "), obj };
}

const providers = [
  {
    id: "sonnet-5",
    gen: (c) => anthropicStream({
      model: "claude-sonnet-5", system: SYSTEM,
      messages: [{ role: "user", content: userContent(c) }],
      effort: "high", maxTokens: 16000, format: { type: "json_schema", schema },
    }),
  },
  {
    id: "qwen3.7-plus",
    gen: (c) => anthropicStream({
      endpoint: "https://dashscope-intl.aliyuncs.com/apps/anthropic/v1/messages",
      apiKey: keys.dashscope, model: "qwen3.7-plus", system: SYSTEM,
      messages: [{ role: "user", content: userContent(c) }],
      effort: "high", maxTokens: 16000, format: { type: "json_schema", schema },
      thinking: { type: "disabled" },
    }),
  },
  {
    id: "deepseek-v4-flash",
    gen: (c) => openaiStream({
      baseURL: "https://openrouter.ai/api/v1", apiKey: keys.openrouter,
      model: "deepseek/deepseek-v4-flash", system: SYSTEM,
      messages: [{ role: "user", content: userContent(c) }], maxTokens: 8192,
      extra: {
        reasoning: { enabled: false },
        provider: { only: ["DeepInfra", "Fireworks"], allow_fallbacks: false, require_parameters: true },
        response_format: { type: "json_schema", json_schema: { name: "session_feedback", strict: true, schema } },
      },
    }),
  },
];

const results = existsSync(OUT) ? JSON.parse(readFileSync(OUT, "utf8")) : {};
const save = () => writeFileSync(OUT, JSON.stringify(results, null, 2));

async function runProvider(p) {
  results[p.id] ??= {};
  for (const c of CASES) {
    results[p.id][c.id] ??= [];
    const runs = results[p.id][c.id];
    while (runs.filter((r) => !r.error).length < GENS) {
      try {
        const r = await p.gen(c);
        const v = validate(r.text);
        runs.push({ text: r.text, ok: v.ok, why: v.why || null, total: r.total, stopReason: r.stopReason ?? r.finishReason ?? null });
        console.log(`[${p.id} ${c.id} #${runs.length}] ok=${v.ok} ${Math.round(r.total / 1000)}s ${v.why ?? ""}`);
      } catch (e) {
        runs.push({ error: String(e.message).slice(0, 300) });
        console.log(`[${p.id} ${c.id}] ERROR: ${String(e.message).slice(0, 200)}`);
        if (runs.filter((r) => r.error).length >= 3) break;
      }
      save();
      await sleep(300);
    }
  }
  console.log(`===== ${p.id} feedback done`);
}

if (process.argv[1] === new URL(import.meta.url).pathname) {
  await Promise.all(providers.map(runProvider));
  save();
  console.log("saved results5-feedback.json");
}
