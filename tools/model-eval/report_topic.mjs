// トピック生成比較の集計（run_topic.mjs の結果を機械チェック + 実額換算）
import { readFileSync } from "node:fs";

const DIR = new URL(".", import.meta.url).pathname;
const results = JSON.parse(readFileSync(`${DIR}results-topic.json`, "utf8"));

// 期待値（本番 system prompt のルール）
const EXPECT = {
  "set-a": ["food", "technology", "childhood"],
  "set-b": ["neighborhood", "mishaps", "aspirations"],
  "set-c": ["housework", "money", "what-if"],
  "set-d": ["sleep", "language", "small-pride"],
  "refill-single": ["celebrations"],
};
const RECENT = {
  "set-a": ["スマホ依存どう思う?", "観るスポーツ派?やる派?", "もしも仕事を変えたら"],
  "set-b": ["朝ごはん何食べる?", "AIが友達になる日"],
  "set-c": [],
  "set-d": ["好きなゲームのやり方", "苦手な家事ある?", "最近買ってよかったもの"],
  "refill-single": ["ペットとの暮らし", "雨の日の過ごし方"],
};

// $ / 1M トークン。gemma は Gemini API 無料枠で $0、括弧内は OpenRouter 従量の参考値
const RATES = {
  "sonnet-5": { in: 3, out: 15 },
  "haiku-4-5": { in: 1, out: 5 },
  "gemma-4-31b-it": { in: 0, out: 0 },
  "gemma-4-31b-it(従量参考)": { in: 0.1, out: 0.35 },
};

const hasJapanese = (s) => /[぀-ヿ㐀-鿿]/.test(s);

// Gemma は responseJsonSchema 指定でも ```json ... ``` のフェンスを混ぜることがある。
// 本番コード（素の JSON.parse）で通るかと、前処理を足せば救えるかを分けて数える。
const stripFence = (s) =>
  s.trim().replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "").trim();

function checkOne(caseId, raw) {
  const issues = [];
  let parsed;
  let neededStrip = false;
  try {
    parsed = JSON.parse(raw);
  } catch {
    try {
      parsed = JSON.parse(stripFence(raw));
      neededStrip = true;
      issues.push("素の JSON.parse 失敗（フェンス剥がしで復旧）");
    } catch {
      return { issues: ["JSON パース失敗（剥がしても不可）"], topics: [], neededStrip: true };
    }
  }
  const topics = parsed?.topics;
  if (!Array.isArray(topics)) {
    return { issues: [...issues, "topics が配列でない"], topics: [], neededStrip };
  }

  const expected = EXPECT[caseId];
  if (topics.length !== expected.length) issues.push(`件数 ${topics.length}（期待 ${expected.length}）`);

  topics.forEach((t, i) => {
    for (const key of ["title", "hook", "genre"]) {
      if (typeof t?.[key] !== "string" || !t[key]) issues.push(`#${i} ${key} 欠落`);
    }
    if (typeof t?.genre === "string" && expected[i] && t.genre !== expected[i]) {
      issues.push(`#${i} genre "${t.genre}"（期待 genre_id "${expected[i]}"）`);
    }
    if (typeof t?.title === "string") {
      const n = [...t.title].length;
      // プロンプトは "roughly four to twelve characters"。大きく外れたものだけ拾う
      if (n < 4 || n > 16) issues.push(`#${i} title ${n} 字 "${t.title}"`);
      if (!hasJapanese(t.title)) issues.push(`#${i} title が日本語でない "${t.title}"`);
    }
    if (typeof t?.hook === "string") {
      const n = [...t.hook].length;
      if (n > 20) issues.push(`#${i} hook ${n} 字（上限 20）"${t.hook}"`);
      if (!hasJapanese(t.hook)) issues.push(`#${i} hook が日本語でない`);
    }
  });

  const titles = topics.map((t) => t?.title).filter((s) => typeof s === "string");
  if (new Set(titles).size !== titles.length) issues.push("候補内でタイトル重複");
  for (const title of titles) {
    if (RECENT[caseId].includes(title)) issues.push(`直近トピックと重複 "${title}"`);
  }
  return { issues, topics, neededStrip };
}

console.log("== トピック生成 機械チェック（5 パターン × 4 生成）==\n");
const summary = {};
for (const [pid, cases] of Object.entries(results)) {
  let total = 0, clean = 0, genreMismatch = 0, hookOver = 0, fenced = 0, unparsable = 0;
  let inTok = 0, outTok = 0;
  const detail = [];
  const allTitles = [];
  for (const [caseId, runs] of Object.entries(cases)) {
    for (const [i, r] of runs.entries()) {
      if (r.error) { detail.push(`${caseId}#${i}: (生成エラー) ${r.error.slice(0, 80)}`); continue; }
      total++;
      inTok += r.usage?.input_tokens ?? 0;
      outTok += r.usage?.output_tokens ?? 0;
      const { issues, topics, neededStrip } = checkOne(caseId, r.text);
      if (neededStrip) fenced++;
      if (issues.some((s) => s.includes("剥がしても不可"))) unparsable++;
      allTitles.push(...topics.map((t) => t?.title).filter(Boolean));
      if (!issues.length) { clean++; continue; }
      if (issues.some((s) => s.includes("genre"))) genreMismatch++;
      if (issues.some((s) => s.includes("hook"))) hookOver++;
      detail.push(`${caseId}#${i}: ${issues.join(" / ")}`);
    }
  }
  summary[pid] = { total, clean, genreMismatch, hookOver, fenced, unparsable, inTok, outTok, allTitles };
  console.log(`-- ${pid}: 違反なし ${clean}/${total}  genre 不一致 ${genreMismatch}  hook 超過 ${hookOver}  フェンス混入 ${fenced}  復旧不能 ${unparsable}`);
  for (const d of detail.slice(0, 12)) console.log(`   ${d}`);
  if (detail.length > 12) console.log(`   ...他 ${detail.length - 12} 件`);
  console.log();
}

console.log("== トークンと料金（20 リクエスト = 5 パターン × 4 生成 ぶん）==\n");
console.log("モデル".padEnd(26) + "入力".padStart(8) + "出力".padStart(8) + "  20 回の実額     1 回あたり");
for (const [pid, s] of Object.entries(summary)) {
  const rate = RATES[pid];
  const cost = (s.inTok / 1e6) * rate.in + (s.outTok / 1e6) * rate.out;
  console.log(
    pid.padEnd(24) + String(s.inTok).padStart(8) + String(s.outTok).padStart(8) +
    `  $${cost.toFixed(5)}     $${(cost / s.total).toFixed(6)}`);
  if (pid.startsWith("gemma")) {
    const r = RATES["gemma-4-31b-it(従量参考)"];
    const c2 = (s.inTok / 1e6) * r.in + (s.outTok / 1e6) * r.out;
    console.log(
      "  └ 従量参考(OpenRouter)".padEnd(24) + "".padStart(16) +
      `  $${c2.toFixed(5)}     $${(c2 / s.total).toFixed(6)}`);
  }
}

console.log("\n== 生成されたタイトル（重複の傾向を見る）==");
for (const [pid, s] of Object.entries(summary)) {
  const counts = {};
  for (const t of s.allTitles) counts[t] = (counts[t] ?? 0) + 1;
  const dupes = Object.entries(counts).filter(([, n]) => n > 1).sort((a, b) => b[1] - a[1]);
  console.log(`\n-- ${pid}: ${s.allTitles.length} 件中 ユニーク ${Object.keys(counts).length} 件`);
  if (dupes.length) {
    console.log(`   同一タイトルの再出現: ${dupes.slice(0, 6).map(([t, n]) => `"${t}"×${n}`).join(", ")}`);
  }
  console.log(`   例: ${s.allTitles.slice(0, 6).map((t) => `"${t}"`).join(", ")}`);
}
