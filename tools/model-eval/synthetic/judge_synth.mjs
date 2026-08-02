// 合成ケースの会話ターンを opus-5 でブラインド A/B 判定する（Phase 5 と同一方式）。
// 順序を入れ替えて 2 回判定し、勝者が一致しなければ tie。
// Gemma は台本形式が成立しない（35/35 致命的違反）ため対象外。
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { anthropicJudge, sleep } from "./lib.mjs";

const DIR = new URL(".", import.meta.url).pathname;
const CASES = JSON.parse(readFileSync(`${DIR}fixtures/cases-synth.json`, "utf8"));
const CONV_SYSTEM = readFileSync(`${DIR}fixtures/system-conversation.txt`, "utf8");
const gen = JSON.parse(readFileSync(`${DIR}results-gen-synth.json`, "utf8"));
const OUT = `${DIR}results-judge-synth.json`;

const BASELINE = "sonnet-5";
const CANDIDATES = ["haiku-4-5"];
const PAIRS = 3; // gen#0-2 同士

const verdictSchema = {
  type: "object",
  properties: {
    a_score: { type: "integer" },
    b_score: { type: "integer" },
    winner: { type: "string", enum: ["A", "B", "tie"] },
    rationale_ja: { type: "string" },
  },
  required: ["a_score", "b_score", "winner", "rationale_ja"],
  additionalProperties: false,
};

const judgeSystem = `You are an expert evaluator for an iOS ESL speaking-practice app. The app currently uses one LLM to script a two-character English conversation ("ESL Group"). We are comparing candidate models against the current one. Model names are hidden; judge only the text.

The production spec every turn must satisfy is below, delimited by <spec> tags. You will then receive the conversation history and two candidate next turns, A and B. The learner utterances come from speech recognition, so they may contain recognition noise.

<spec>
${CONV_SYSTEM}
</spec>

Judge which candidate is the better next turn for a Japanese adult ESL learner, focusing on SUBJECTIVE quality:
- Naturalness: does it read like real, warm human small talk (spoken aloud via TTS), not stiff or generic?
- Fit for the learner: simple English, short turns, hands the conversation back, keeps the learner talking.
- Character consistency: Chobi = calm warm host with light tsukkomi; Naruko = cheerful fellow learner.
- Situation handling: does it do the right thing for this specific situation (e.g. reacting to content, handling speech-recognition noise or Japanese input per the spec, closing a session, opening a topic)?
Mechanical format compliance (tags, line counts) is checked separately by scripts — only weigh a format issue here if it would badly damage the experience.

Score each candidate 1-10 (10 = ideal turn). winner is the better one, or "tie" if genuinely comparable. Write rationale_ja as 2-4 short sentences in Japanese.`;

const historyText = (messages) =>
  messages.map((m) => `[${m.role}]\n${m.content}`).join("\n\n");

// winner(A/B) を「候補が勝ったか」へ変換する。candidateIs は候補がどちら側に置かれたか
const toCandidate = (winner, candidateIs) =>
  winner === "tie" ? "tie" : winner === candidateIs ? "candidate" : "baseline";

const results = existsSync(OUT) ? JSON.parse(readFileSync(OUT, "utf8")) : {};

for (const candidate of CANDIDATES) {
  results[candidate] ??= {};
  for (const c of CASES.conversation) {
    results[candidate][c.id] ??= [];
    while (results[candidate][c.id].length < PAIRS) {
      const index = results[candidate][c.id].length;
      const baseText = gen[BASELINE]?.[c.id]?.[index]?.text;
      const candText = gen[candidate]?.[c.id]?.[index]?.text;
      if (!baseText || !candText) {
        results[candidate][c.id].push({ error: "生成が揃っていない" });
        continue;
      }
      process.stdout.write(`${candidate} ${c.id}#${index} ... `);
      const verdicts = [];
      try {
        // 1 回目: A=baseline, B=candidate / 2 回目: 入れ替え
        for (const [aText, bText, candidateIs] of [
          [baseText, candText, "B"],
          [candText, baseText, "A"],
        ]) {
          const { result } = await anthropicJudge({
            system: judgeSystem,
            schema: verdictSchema,
            messages: [{
              role: "user",
              content: `## Conversation history\n\n${historyText(c.messages)}\n\n`
                + `## Candidate A\n\n${aText}\n\n## Candidate B\n\n${bText}`,
            }],
          });
          verdicts.push({ ...result, candidateIs, outcome: toCandidate(result.winner, candidateIs) });
          await sleep(400);
        }
        const [v1, v2] = verdicts;
        const agreed = v1.outcome === v2.outcome ? v1.outcome : "tie";
        results[candidate][c.id].push({ verdicts, outcome: agreed });
        console.log(`${agreed}${v1.outcome !== v2.outcome ? "（不一致→tie）" : ""}`);
      } catch (error) {
        results[candidate][c.id].push({ error: String(error).slice(0, 200) });
        console.log(`ERROR ${String(error).slice(0, 100)}`);
      }
      writeFileSync(OUT, JSON.stringify(results, null, 2));
    }
  }
}

// 集計
console.log("\n== ブラインド A/B 集計（baseline = claude-sonnet-5）==");
for (const [candidate, cases] of Object.entries(results)) {
  const tally = { candidate: 0, baseline: 0, tie: 0, error: 0 };
  const perCase = [];
  for (const [cid, runs] of Object.entries(cases)) {
    const local = { candidate: 0, baseline: 0, tie: 0 };
    for (const r of runs) {
      if (r.error) { tally.error++; continue; }
      tally[r.outcome]++;
      local[r.outcome]++;
    }
    perCase.push(`  ${cid.padEnd(20)} 候補勝ち ${local.candidate} / 現行勝ち ${local.baseline} / 引分 ${local.tie}`);
  }
  const n = tally.candidate + tally.baseline + tally.tie;
  console.log(`\n-- ${candidate} vs sonnet-5（${n} ペア）`);
  console.log(`   候補(${candidate}) 勝ち ${tally.candidate} / 現行(sonnet-5) 勝ち ${tally.baseline} / 引分 ${tally.tie}` +
    (tally.error ? ` / エラー ${tally.error}` : ""));
  for (const line of perCase) console.log(line);
}
console.log(`\n→ ${OUT}`);
