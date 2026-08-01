// Phase 5 機械チェック集計: 単発ターン (results5-gen) + マルチターン再生 (results5-replay)
import { readFileSync, existsSync } from "node:fs";
import { checkTurn, isCritical } from "./checklib5.mjs";

const DIR = new URL(".", import.meta.url).pathname;
const CASES = JSON.parse(readFileSync(`${DIR}fixtures/cases5.json`, "utf8"));
const gen = JSON.parse(readFileSync(`${DIR}results5-gen.json`, "utf8"));
const allCases = [...CASES.conversation, ...CASES.wordquiz];
const caseById = Object.fromEntries(allCases.map((c) => [c.id, c]));

console.log("== 単発ターン機械チェック (5 生成 / ケース) ==");
const summary = {};
for (const [pid, cases] of Object.entries(gen)) {
  let total = 0, clean = 0, critical = 0;
  const detail = [];
  for (const [cid, runs] of Object.entries(cases)) {
    const c = caseById[cid];
    if (!c) continue;
    for (const [i, r] of runs.entries()) {
      if (r.error) { detail.push(`${cid}#${i}: (生成エラー) ${r.error.slice(0, 80)}`); continue; }
      total++;
      const issues = checkTurn(r.text, c);
      if (!issues.length) { clean++; continue; }
      if (issues.some(isCritical)) critical++;
      detail.push(`${cid}#${i}: ${issues.join(" / ")}`);
    }
  }
  summary[pid] = { total, clean, critical };
  console.log(`\n-- ${pid}: clean ${clean}/${total}  致命的違反あり ${critical}/${total}`);
  for (const d of detail) console.log(`   ${d}`);
}

// 会話ケースのみの致命的違反率 (合否基準用)
console.log("\n== 会話ケースのみ (合否基準の対象) ==");
const convIds = new Set(CASES.conversation.map((c) => c.id));
for (const [pid, cases] of Object.entries(gen)) {
  let total = 0, critical = 0, clean = 0;
  for (const [cid, runs] of Object.entries(cases)) {
    if (!convIds.has(cid)) continue;
    for (const r of runs) {
      if (r.error) continue;
      total++;
      const issues = checkTurn(r.text, caseById[cid]);
      if (!issues.length) clean++;
      if (issues.some(isCritical)) critical++;
    }
  }
  console.log(`${pid}: clean ${clean}/${total} (${Math.round((clean / total) * 100)}%)  致命的 ${critical}/${total} (${Math.round((critical / total) * 100)}%)`);
}

// マルチターン再生
const replayPath = `${DIR}results5-replay.json`;
if (existsSync(replayPath)) {
  const replay = JSON.parse(readFileSync(replayPath, "utf8"));
  console.log("\n== マルチターン再生 (全ターン通常ターン扱い) ==");
  for (const [pid, cases] of Object.entries(replay)) {
    for (const [rid, rc] of Object.entries(cases)) {
      let total = 0, clean = 0, critical = 0;
      const notes = [];
      for (const t of rc.turns) {
        if (t.error) { notes.push(`t${t.turn}: エラー`); continue; }
        total++;
        // t0 は開幕ターン ([Memory]+[New topic:] 直後) なので 3 発話まで許容
        const issues = checkTurn(t.text, { expectEnd: "no", topicOpening: t.turn === 0 });
        if (!issues.length) clean++;
        if (issues.some(isCritical)) critical++;
        if (issues.length) notes.push(`t${t.turn}: ${issues.join(" / ")}`);
        if (t.endedEarly) notes.push(`t${t.turn}: [end] 誤出力で打ち切り`);
      }
      console.log(`${pid} ${rid}: ${rc.turns.length}/${rc.plannedTurns} ターン完走  clean ${clean}/${total}  致命的 ${critical}/${total}`);
      for (const n of notes) console.log(`   ${n}`);
    }
  }
}
