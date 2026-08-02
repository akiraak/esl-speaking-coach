// 合成ケースの単発ターン生成の機械チェック集計（checklib5.mjs をそのまま使う）
import { readFileSync } from "node:fs";
import { checkTurn, isCritical } from "./checklib5.mjs";

const DIR = new URL(".", import.meta.url).pathname;
const CASES = JSON.parse(readFileSync(`${DIR}fixtures/cases-synth.json`, "utf8"));
const gen = JSON.parse(readFileSync(`${DIR}results-gen-synth.json`, "utf8"));
const allCases = [...CASES.conversation, ...CASES.wordquiz];
const caseById = Object.fromEntries(allCases.map((c) => [c.id, c]));

// $ / 1M トークン。gemma は Gemini API 無料枠 = $0（括弧は OpenRouter 従量の参考）
const RATES = {
  "sonnet-5": { in: 3, out: 15, cacheRead: 0.3, cacheWrite: 3.75 },
  "haiku-4-5": { in: 1, out: 5, cacheRead: 0.1, cacheWrite: 1.25 },
  "gemma-4-31b-it": { in: 0, out: 0, cacheRead: 0, cacheWrite: 0 },
};
const GEMMA_METERED = { in: 0.1, out: 0.35 };

console.log("== 単発ターン 機械チェック（12 ケース × 3 生成）==");
const summary = {};
for (const [pid, cases] of Object.entries(gen)) {
  let total = 0, clean = 0, critical = 0;
  let inTok = 0, outTok = 0, cacheRead = 0, cacheWrite = 0;
  const detail = [];
  for (const [cid, runs] of Object.entries(cases)) {
    const c = caseById[cid];
    if (!c) continue;
    for (const [i, r] of runs.entries()) {
      if (r.error) { detail.push(`${cid}#${i}: (生成エラー) ${r.error.slice(0, 80)}`); continue; }
      total++;
      inTok += r.usage?.input_tokens ?? 0;
      outTok += r.usage?.output_tokens ?? 0;
      cacheRead += r.usage?.cache_read_input_tokens ?? 0;
      cacheWrite += r.usage?.cache_creation_input_tokens ?? 0;
      const issues = checkTurn(r.text, c);
      if (!issues.length) { clean++; continue; }
      if (issues.some(isCritical)) critical++;
      detail.push(`${cid}#${i}: ${issues.join(" / ")}`);
    }
  }
  summary[pid] = { total, clean, critical, inTok, outTok, cacheRead, cacheWrite };
  console.log(`\n-- ${pid}: 違反なし ${clean}/${total}  致命的違反あり ${critical}/${total}`);
  for (const d of detail) console.log(`   ${d}`);
}

console.log("\n== トークンと料金（36 リクエスト = 12 ケース × 3 生成）==\n");
console.log("モデル".padEnd(24) + "入力".padStart(9) + "cache読".padStart(9) + "cache書".padStart(9) + "出力".padStart(8) + "   36 回の実額");
for (const [pid, s] of Object.entries(summary)) {
  const r = RATES[pid];
  const cost = (s.inTok / 1e6) * r.in + (s.cacheRead / 1e6) * r.cacheRead
    + (s.cacheWrite / 1e6) * r.cacheWrite + (s.outTok / 1e6) * r.out;
  console.log(
    pid.padEnd(22) + String(s.inTok).padStart(9) + String(s.cacheRead).padStart(9) +
    String(s.cacheWrite).padStart(9) + String(s.outTok).padStart(8) + `   $${cost.toFixed(5)}`);
  if (pid.startsWith("gemma")) {
    const c2 = (s.inTok / 1e6) * GEMMA_METERED.in + (s.outTok / 1e6) * GEMMA_METERED.out;
    console.log("  └ 従量参考(OpenRouter)".padEnd(22) + "".padStart(35) + `   $${c2.toFixed(5)}`);
  }
}

// TTS で読み上げる前提なので、音にならない記号は品質に効く
// （system prompt も「no markdown, no text in parentheses」と禁じている）
console.log("\n== TTS で読みにくい記号（生成に含まれる総数）==\n");
console.log("モデル".padEnd(24) + "ダッシュ".padStart(9) + "三点リーダ".padStart(11) + "括弧書き".padStart(10));
for (const pid of Object.keys(summary)) {
  let dash = 0, ellipsis = 0, paren = 0;
  for (const runs of Object.values(gen[pid] ?? {})) {
    for (const r of runs) {
      if (r.error) continue;
      dash += (r.text.match(/[—–]|(?<=\w)--(?=\w)/g) ?? []).length;
      ellipsis += (r.text.match(/\.\.\.|…/g) ?? []).length;
      paren += (r.text.match(/\([^)]*\)/g) ?? []).length;
    }
  }
  console.log(pid.padEnd(22) + String(dash).padStart(9) + String(ellipsis).padStart(11) + String(paren).padStart(10));
}

// キャッシュが効いているかの裏取り（プランの中心的な論点）
console.log("\n== プロンプトキャッシュ ==");
for (const [pid, s] of Object.entries(summary)) {
  if (pid.startsWith("gemma")) { console.log(`  ${pid}: Gemini API にプロンプトキャッシュの概念なし`); continue; }
  const status = s.cacheRead > 0 ? `効いている（cache_read ${s.cacheRead} トークン）` : "効いていない（cache_read = 0）";
  console.log(`  ${pid}: ${status}`);
}
