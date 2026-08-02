// マルチターン再生: 学習者の発話を固定し、AI ターンだけを各モデルで先頭から順に再生成する。
// 候補モデル自身の出力が履歴に積まれていく状態を再現するので、単発ターン評価では見えない
// 「文脈の引き継ぎ」「同じ話の繰り返し」「キャラの一貫性」が出る。
// Gemma は台本形式が成立しないため対象外（単発で 35/35 致命的違反）。
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { keys, anthropicStream, sleep } from "./lib.mjs";

const DIR = new URL(".", import.meta.url).pathname;
const CASES = JSON.parse(readFileSync(`${DIR}fixtures/cases-synth.json`, "utf8"));
const SYSTEM = readFileSync(`${DIR}fixtures/system-conversation.txt`, "utf8");
const OUT = `${DIR}results-replay-synth.json`;

const providers = [
  {
    id: "sonnet-5",
    gen: (messages) => anthropicStream({
      model: "claude-sonnet-5", system: SYSTEM, messages, effort: "low", maxTokens: 1024,
    }),
  },
  {
    id: "haiku-4-5",
    gen: (messages) => anthropicStream({
      model: "claude-haiku-4-5", system: SYSTEM, messages, maxTokens: 1024,
    }),
  },
];

const results = existsSync(OUT) ? JSON.parse(readFileSync(OUT, "utf8")) : {};

for (const provider of providers) {
  if (!keys.anthropic) continue;
  results[provider.id] ??= {};
  for (const replay of CASES.replay) {
    if (results[provider.id][replay.id]?.done) continue;
    console.log(`\n== ${provider.id} / ${replay.id}（${replay.topicTitle}）`);
    // 開幕: [Memory: ...]\n[New topic: ...] を user として与え、AI ターンを生成させる
    const messages = [{ role: "user", content: replay.opening }];
    const turns = [];
    let failed = false;
    for (let i = 0; i <= replay.learnerTurns.length; i++) {
      process.stdout.write(`  turn ${i} ... `);
      try {
        const r = await provider.gen(messages);
        turns.push({ index: i, text: r.text, usage: r.usage, stopReason: r.stopReason });
        messages.push({ role: "assistant", content: r.text });
        console.log(`ok (${r.text.split("\n").filter(Boolean).length} lines)`);
      } catch (error) {
        turns.push({ index: i, error: String(error).slice(0, 200) });
        console.log(`ERROR ${String(error).slice(0, 100)}`);
        failed = true;
        break;
      }
      // 次の学習者発話を積む（最後のターンの後は無い）
      if (i < replay.learnerTurns.length) {
        messages.push({ role: "user", content: replay.learnerTurns[i] });
      }
      await sleep(400);
    }
    results[provider.id][replay.id] = {
      done: !failed, topicTitle: replay.topicTitle,
      opening: replay.opening, learnerTurns: replay.learnerTurns, turns,
    };
    writeFileSync(OUT, JSON.stringify(results, null, 2));
  }
}

console.log(`\n→ ${OUT}`);
for (const [pid, sessions] of Object.entries(results)) {
  for (const [rid, s] of Object.entries(sessions)) {
    const ok = s.turns.filter((t) => !t.error).length;
    console.log(`  ${pid} / ${rid}: ${ok}/${s.turns.length} ターン生成`);
  }
}
