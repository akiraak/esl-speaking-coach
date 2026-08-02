// 合成 transcript に仕込んだ「学習者の誤り」を、各モデルのフィードバックが
// どれだけ拾えたか（リコール）を測る。合成 fixture だからこそできる評価。
// 誤りの一覧は build_export.py で意図的に入れたものと対応している。
import { readFileSync } from "node:fs";

const DIR = new URL(".", import.meta.url).pathname;
const results = JSON.parse(readFileSync(`${DIR}results-feedback-synth.json`, "utf8"));

// key: transcript に仕込んだ誤り。match は corrections.original に含まれるべき手がかり
const PLANTED = {
  "fb-1111": [ // 週末の失敗談
    { id: "try-cook", match: ["i try to cook", "try to cook"], label: "時制（try→tried）" },
    { id: "forget-rice", match: ["i forget the rice", "forget the rice"], label: "時制（forget→forgot）" },
    { id: "many-chili", match: ["many chili"], label: "不可算（many→a lot of / chilies）" },
    { id: "weak-person", match: ["weak person"], label: "冠詞落ち（a weak person）" },
    { id: "i-drink-milk", match: ["i drink milk", "drink milk"], label: "時制（drink→drank）" },
  ],
  "fb-2222": [ // 朝型か夜型か
    { id: "read-book", match: ["read book"], label: "冠詞落ち（a book / books）" },
    { id: "sometime", match: ["sometime i study", "sometime"], label: "副詞（sometime→sometimes）" },
    { id: "night-person", match: ["was night person", "night person"], label: "冠詞落ち（a night person）" },
    { id: "son-born", match: ["my son born", "son born"], label: "受動態（my son was born）" },
    { id: "want-watch", match: ["i want to watch movie", "watch movie"], label: "冠詞落ち（a movie）" },
    { id: "little-difficult", match: ["little difficult"], label: "a little difficult" },
  ],
  "fb-3333": [ // もし引っ越すなら
    { id: "go-last-year", match: ["i go there last year", "go there last year"], label: "時制（go→went）" },
    { id: "cheap-than", match: ["cheap than"], label: "比較級（cheaper than）" },
    { id: "mansion", match: ["mansion"], label: "和製英語（mansion→apartment）" },
    { id: "wife-want", match: ["wife want"], label: "三単現（wants）" },
    { id: "someday-discuss", match: ["someday we discuss"], label: "未来形（will discuss）" },
    { id: "company-allow", match: ["company allow"], label: "三単現（allows）" },
    { id: "five-minutes-walking", match: ["five minutes walking"], label: "a five-minute walk" },
  ],
  "fb-4444": [ // put off
    { id: "busy-in-work", match: ["busy in work"], label: "前置詞（busy at work / with work）" },
    { id: "company-decide", match: ["company decide"], label: "時制＋三単現（decided）" },
    { id: "understand-almost", match: ["understand almost"], label: "語順（almost understand）" },
  ],
};

const strip = (s) => s.trim().replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "").trim();
const norm = (s) => s.toLowerCase().replace(/[.,!?"'’“”…\-—]/g, "").replace(/\s+/g, " ").trim();

console.log("== 仕込んだ誤りの検出率（合成 fixture だからこそ測れる指標）==\n");

const perModel = {};
for (const [pid, cases] of Object.entries(results)) {
  const found = new Map(); // 誤り id → 何回の生成で拾えたか
  let gens = 0;
  const totalPlanted = Object.values(PLANTED).flat().length;
  for (const [cid, planted] of Object.entries(PLANTED)) {
    for (const r of results[pid]?.[cid] ?? []) {
      if (r.error) continue;
      let parsed = null;
      try { parsed = JSON.parse(r.text); } catch { try { parsed = JSON.parse(strip(r.text)); } catch {} }
      if (!parsed) continue;
      gens++;
      const originals = (parsed.corrections ?? []).map((c) => norm(String(c?.original ?? "")));
      for (const p of planted) {
        const hit = p.match.some((m) => originals.some((o) => o.includes(norm(m))));
        const key = `${cid}:${p.id}`;
        if (hit) found.set(key, (found.get(key) ?? 0) + 1);
      }
    }
  }
  // 「3 生成のうち 1 回でも拾えた誤り」の数（少なくとも一度は気づけるか）
  const everFound = found.size;
  perModel[pid] = { everFound, totalPlanted, gens, found };
  console.log(`-- ${pid}: 仕込んだ ${totalPlanted} 件中 ${everFound} 件を検出（3 生成のうち 1 回以上）`);
}

console.log("\n== 誤りごとの検出（○ = 3 生成中の検出回数）==\n");
const header = "誤り".padEnd(42) + Object.keys(perModel).map((p) => p.slice(0, 9).padStart(11)).join("");
console.log(header);
for (const [cid, planted] of Object.entries(PLANTED)) {
  for (const p of planted) {
    const key = `${cid}:${p.id}`;
    const row = Object.values(perModel).map((m) => {
      const n = m.found.get(key) ?? 0;
      return (n ? `${n}/3` : "—").padStart(11);
    }).join("");
    console.log(`${cid} ${p.label}`.padEnd(42) + row);
  }
}

console.log("\n注: 誤りの一覧は synthetic/build_export.py で意図的に仕込んだもの。");
console.log("    「拾わないこと」が常に悪いわけではない（system prompt は最大 5 件・有用な順と指示している）が、");
console.log("    理解を妨げる誤り（和製英語など）を落としているかは品質の指標になる。");
