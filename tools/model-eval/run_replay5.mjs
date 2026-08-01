// Phase 5 Step 3: マルチターン再生評価
// 実セッションの学習者発話を固定し、AI ターンだけを候補モデルで先頭から順に再生成する
// (候補モデル自身の出力が履歴に積まれる状態を再現)。リクエスト形は本番同一。
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { keys, anthropicStream, sleep } from "./lib.mjs";

const DIR = new URL(".", import.meta.url).pathname;
const CASES = JSON.parse(readFileSync(`${DIR}fixtures/cases5.json`, "utf8"));
const SYSTEM = readFileSync(`${DIR}fixtures/system-conversation.txt`, "utf8");
const OUT = `${DIR}results5-replay.json`;

const providers = [
  {
    id: "sonnet-5",
    gen: (messages) => anthropicStream({
      model: "claude-sonnet-5", system: SYSTEM, messages, effort: "low", maxTokens: 1024,
    }),
  },
  {
    id: "qwen3.7-plus",
    gen: (messages) => anthropicStream({
      endpoint: "https://dashscope-intl.aliyuncs.com/apps/anthropic/v1/messages",
      apiKey: keys.dashscope, model: "qwen3.7-plus", system: SYSTEM, messages,
      effort: "low", maxTokens: 1024, thinking: { type: "disabled" },
    }),
  },
  {
    id: "qwen3.7-flash",
    gen: (messages) => anthropicStream({
      endpoint: "https://dashscope-intl.aliyuncs.com/apps/anthropic/v1/messages",
      apiKey: keys.dashscope, model: "qwen3.7-flash", system: SYSTEM, messages,
      effort: "low", maxTokens: 1024, thinking: { type: "disabled" },
    }),
  },
];

const results = existsSync(OUT) ? JSON.parse(readFileSync(OUT, "utf8")) : {};
const save = () => writeFileSync(OUT, JSON.stringify(results, null, 2));

async function runProvider(p) {
  results[p.id] ??= {};
  for (const rc of CASES.replay) {
    if (results[p.id][rc.id]?.done) continue;
    const userTurns = rc.history.filter((m) => m.role === "user").map((m) => m.text);
    const messages = [];
    const turns = [];
    console.log(`===== ${p.id} ${rc.id} (${userTurns.length} learner turns)`);
    for (let k = 0; k < userTurns.length; k++) {
      messages.push({ role: "user", content: userTurns[k] });
      try {
        const r = await p.gen(messages);
        messages.push({ role: "assistant", content: r.text });
        turns.push({ turn: k, text: r.text, stopReason: r.stopReason, ttft: r.ttft });
        console.log(`  [${p.id} ${rc.id} t${k}] len=${r.text.length}`);
        if (r.text.includes("[end]")) {
          // 再生成側が [end] を出したらそのターンで打ち切り (誤終了として記録される)
          turns.at(-1).endedEarly = true;
          console.log(`  [${p.id} ${rc.id} t${k}] [end] を出力 → 打ち切り`);
          break;
        }
      } catch (e) {
        turns.push({ turn: k, error: String(e.message).slice(0, 300) });
        console.log(`  [${p.id} ${rc.id} t${k}] ERROR: ${String(e.message).slice(0, 200)}`);
        break;
      }
      await sleep(250);
    }
    results[p.id][rc.id] = { done: true, turns, plannedTurns: userTurns.length };
    save();
  }
  console.log(`===== ${p.id} replay done`);
}

await Promise.all(providers.map(runProvider));
save();
console.log("saved results5-replay.json");
