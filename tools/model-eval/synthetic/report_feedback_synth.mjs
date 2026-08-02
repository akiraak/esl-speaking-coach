// フィードバック生成の機械チェック集計。
// system prompt のルールのうち自動判定できるものを見る。中でも重要なのは
// 「corrections.original が学習者の発話に実在するか」— AI キャラの発話を拾ったり、
// 誤りを捏造したりしていないかがここで分かる。
import { readFileSync } from "node:fs";

const DIR = new URL(".", import.meta.url).pathname;
const CASES = JSON.parse(readFileSync(`${DIR}fixtures/cases-synth.json`, "utf8"));
const results = JSON.parse(readFileSync(`${DIR}results-feedback-synth.json`, "utf8"));
const caseById = Object.fromEntries(CASES.feedback.map((c) => [c.id, c]));

const RATES = {
  "sonnet-5": { in: 3, out: 15, cacheRead: 0.3, cacheWrite: 3.75 },
  "haiku-4-5": { in: 1, out: 5, cacheRead: 0.1, cacheWrite: 1.25 },
  "gemma-4-31b-it": { in: 0, out: 0, cacheRead: 0, cacheWrite: 0 },
};
const GEMMA_METERED = { in: 0.1, out: 0.35 };

const hasJapanese = (s) => /[぀-ヿ㐀-鿿]/.test(s);
const stripFence = (s) =>
  s.trim().replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "").trim();
// 比較用の正規化（大小・約物・空白を落として部分一致を見る）
const norm = (s) => s.toLowerCase().replace(/[.,!?"'’“”…\-—]/g, "").replace(/\s+/g, " ").trim();

function learnerAndAiLines(transcript) {
  const learner = [];
  const ai = [];
  for (const line of transcript.split("\n")) {
    if (line.startsWith("Learner: ")) learner.push(norm(line.slice(9)));
    else if (/^(Chobi|Naruko): /.test(line)) ai.push(norm(line.replace(/^(Chobi|Naruko): /, "")));
  }
  return { learner, ai };
}

console.log("== フィードバック 機械チェック（4 transcript × 3 生成）==");
const summary = {};
for (const [pid, cases] of Object.entries(results)) {
  let total = 0, clean = 0, fenced = 0, truncated = 0, notFromLearner = 0, fromAi = 0;
  let inTok = 0, outTok = 0, cacheRead = 0, cacheWrite = 0;
  const detail = [];
  for (const [cid, runs] of Object.entries(cases)) {
    const c = caseById[cid];
    if (!c) continue;
    const { learner, ai } = learnerAndAiLines(c.transcript);
    for (const [i, r] of runs.entries()) {
      if (r.error) { detail.push(`${cid}#${i}: (生成エラー) ${r.error.slice(0, 80)}`); continue; }
      total++;
      inTok += r.usage?.input_tokens ?? 0;
      outTok += r.usage?.output_tokens ?? 0;
      cacheRead += r.usage?.cache_read_input_tokens ?? 0;
      cacheWrite += r.usage?.cache_creation_input_tokens ?? 0;

      const issues = [];
      if (r.stopReason && !["end_turn", "STOP", "stop"].includes(r.stopReason)) {
        issues.push(`stop_reason=${r.stopReason}（途中で切れた疑い）`);
        truncated++;
      }
      let parsed = null;
      try {
        parsed = JSON.parse(r.text);
      } catch {
        try { parsed = JSON.parse(stripFence(r.text)); fenced++; issues.push("素の JSON.parse 失敗（フェンス剥がしで復旧）"); }
        catch { issues.push("JSON パース失敗（剥がしても不可）"); }
      }
      if (parsed) {
        const { summary: sum, corrections, try_phrases: tries } = parsed;
        if (typeof sum !== "string" || !sum) issues.push("summary 欠落");
        else {
          if (!hasJapanese(sum)) issues.push("summary が日本語でない");
          if (/[?？]/.test(sum)) issues.push("summary に質問が含まれる");
          if (/[*#`>|]|^- /m.test(sum)) issues.push("summary に markdown");
          if (/\p{Extended_Pictographic}/u.test(sum)) issues.push("summary に絵文字");
          if (!/(です|ます)[。.]?/.test(sum)) issues.push("summary が desu-masu でない");
        }
        if (!Array.isArray(corrections)) issues.push("corrections が配列でない");
        else {
          if (corrections.length > 5) issues.push(`corrections ${corrections.length} 件（上限 5）`);
          corrections.forEach((x, j) => {
            const o = norm(String(x?.original ?? ""));
            if (!o) { issues.push(`correction#${j} original 空`); return; }
            const inLearner = learner.some((l) => l.includes(o));
            if (!inLearner) {
              const inAi = ai.some((l) => l.includes(o));
              if (inAi) { issues.push(`correction#${j} が AI の発話由来: "${x.original}"`); fromAi++; }
              else { issues.push(`correction#${j} が transcript に無い: "${x.original}"`); notFromLearner++; }
            }
            const note = String(x?.note ?? "");
            if (!hasJapanese(note)) issues.push(`correction#${j} note が日本語でない`);
            if ([...note].length > 50) issues.push(`correction#${j} note ${[...note].length} 字（目安 40）`);
          });
        }
        if (!Array.isArray(tries)) issues.push("try_phrases が配列でない");
        else {
          if (tries.length < 2 || tries.length > 3) issues.push(`try_phrases ${tries.length} 件（規定 2〜3）`);
          tries.forEach((x, j) => {
            if (!hasJapanese(String(x?.meaning ?? ""))) issues.push(`try_phrase#${j} meaning が日本語でない`);
          });
        }
      }
      if (!issues.length) clean++;
      else detail.push(`${cid}#${i}: ${issues.join(" / ")}`);
    }
  }
  summary[pid] = { total, clean, fenced, truncated, notFromLearner, fromAi, inTok, outTok, cacheRead, cacheWrite };
  console.log(`\n-- ${pid}: 違反なし ${clean}/${total}  ` +
    `切れ ${truncated}  フェンス ${fenced}  AI 発話を添削 ${fromAi}  transcript 外 ${notFromLearner}`);
  for (const d of detail.slice(0, 14)) console.log(`   ${d}`);
  if (detail.length > 14) console.log(`   ...他 ${detail.length - 14} 件`);
}

console.log("\n== トークンと料金（12 リクエスト = 4 transcript × 3 生成）==\n");
console.log("モデル".padEnd(24) + "入力".padStart(9) + "cache読".padStart(9) + "出力".padStart(8) + "   12 回の実額");
for (const [pid, s] of Object.entries(summary)) {
  const r = RATES[pid];
  const cost = (s.inTok / 1e6) * r.in + (s.cacheRead / 1e6) * r.cacheRead
    + (s.cacheWrite / 1e6) * r.cacheWrite + (s.outTok / 1e6) * r.out;
  console.log(pid.padEnd(22) + String(s.inTok).padStart(9) + String(s.cacheRead).padStart(9)
    + String(s.outTok).padStart(8) + `   $${cost.toFixed(5)}`);
  if (pid.startsWith("gemma")) {
    const c2 = (s.inTok / 1e6) * GEMMA_METERED.in + (s.outTok / 1e6) * GEMMA_METERED.out;
    console.log("  └ 従量参考(OpenRouter)".padEnd(22) + "".padStart(26) + `   $${c2.toFixed(5)}`);
  }
}
