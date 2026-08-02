// 記憶ノート更新の集計。ノートは「次のセッションで AI が学習者を思い出す」ための入力なので、
// 情報が落ちていないか（前回ノートの項目を引き継げているか）と分量を見る。
import { readFileSync } from "node:fs";

const DIR = new URL(".", import.meta.url).pathname;
const results = JSON.parse(readFileSync(`${DIR}results-memory-synth.json`, "utf8"));

const RATES = {
  "sonnet-5": { in: 3, out: 15, cacheRead: 0.3, cacheWrite: 3.75 },
  "haiku-4-5": { in: 1, out: 5, cacheRead: 0.1, cacheWrite: 1.25 },
  "gemma-4-31b-it": { in: 0, out: 0, cacheRead: 0, cacheWrite: 0 },
};
const GEMMA_METERED = { in: 0.1, out: 0.35 };

const strip = (s) => s.trim().replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "").trim();
const parse = (raw) => {
  try { return [JSON.parse(raw), false]; } catch {}
  try { return [JSON.parse(strip(raw)), true]; } catch { return [null, true]; }
};

// 前回ノートに入っていた事実。更新後も残っているべきもの（引き継ぎの取りこぼしを見る）
const CARRY_OVER = [
  { key: "tokyo", match: [/tokyo/i] },
  { key: "it-work", match: [/\bIT\b/, /works in IT/i] },
  { key: "son", match: [/son/i] },
  { key: "5:30", match: [/5[:.]30/, /five thirty/i, /5 ?am/i] },
  { key: "ramen", match: [/ramen/i] },
  { key: "meetings", match: [/meeting/i] },
];

console.log("== 記憶ノート更新 ==\n");
const summary = {};
for (const [pid, targets] of Object.entries(results)) {
  let total = 0, fenced = 0, failed = 0, lengthSum = 0;
  let inTok = 0, outTok = 0, cacheRead = 0, cacheWrite = 0;
  const missing = new Map();
  for (const [tid, runs] of Object.entries(targets)) {
    const withPrevious = tid.endsWith("with-previous");
    for (const r of runs) {
      if (r.error) { failed++; continue; }
      total++;
      inTok += r.usage?.input_tokens ?? 0;
      outTok += r.usage?.output_tokens ?? 0;
      cacheRead += r.usage?.cache_read_input_tokens ?? 0;
      cacheWrite += r.usage?.cache_creation_input_tokens ?? 0;
      const [parsed, needStrip] = parse(r.text);
      if (needStrip && parsed) fenced++;
      if (!parsed) { failed++; continue; }
      const note = String(parsed.memory ?? "");
      lengthSum += note.length;
      if (!withPrevious) continue; // 引き継ぎは「前回ノートあり」でのみ見る
      for (const c of CARRY_OVER) {
        if (!c.match.some((re) => re.test(note))) {
          missing.set(c.key, (missing.get(c.key) ?? 0) + 1);
        }
      }
    }
  }
  summary[pid] = { total, fenced, failed, avgLen: Math.round(lengthSum / (total || 1)),
    inTok, outTok, cacheRead, cacheWrite, missing };
  const miss = [...missing.entries()].map(([k, n]) => `${k}×${n}`).join(", ") || "なし";
  console.log(`-- ${pid}: ${total} 生成  平均 ${summary[pid].avgLen} 字  フェンス ${fenced}  失敗 ${failed}`);
  console.log(`   前回ノートの項目の取りこぼし: ${miss}`);
}

console.log("\n== トークンと料金 ==\n");
console.log("モデル".padEnd(24) + "入力".padStart(9) + "cache読".padStart(9) + "出力".padStart(8) + "   実額");
for (const [pid, s] of Object.entries(summary)) {
  const r = RATES[pid];
  const cost = (s.inTok / 1e6) * r.in + (s.cacheRead / 1e6) * r.cacheRead
    + (s.cacheWrite / 1e6) * r.cacheWrite + (s.outTok / 1e6) * r.out;
  console.log(pid.padEnd(22) + String(s.inTok).padStart(9) + String(s.cacheRead).padStart(9)
    + String(s.outTok).padStart(8) + `   $${cost.toFixed(5)}（${s.total} 回）`);
  if (pid.startsWith("gemma")) {
    const c2 = (s.inTok / 1e6) * GEMMA_METERED.in + (s.outTok / 1e6) * GEMMA_METERED.out;
    console.log("  └ 従量参考(OpenRouter)".padEnd(22) + "".padStart(26) + `   $${c2.toFixed(5)}`);
  }
}
