// 記憶ノートが予算内に収まるかを実 API で測る（docs/plans/memory-note-length.md）。
//
// 使い方（リポジトリ直下から）:
//   node tools/memory-length/run.mjs bloated   # 太ったノート（605 語）を渡し、縮むことを見る
//   node tools/memory-length/run.mjs small     # 健全なノート（130 語）を渡し、削りすぎないことを見る
//   node tools/memory-length/run.mjs both
//
// system prompt は Swift（MemoryUpdateClient.systemPrompt）から毎回抽出するので、
// プロンプトを変えたら再実行するだけでよい。生成物は全文を標準出力へ出す
// （語数の集計だけでは、事実が壊れたか・過剰に削られたかが見えないため）。
import { readFileSync, mkdirSync, rmSync } from "node:fs";
import { execFileSync } from "node:child_process";
import path from "node:path";

const ROOT = "/Users/akiraak/Projects/esl-speaking-coach";
const FIXTURES = path.join(ROOT, "tools/memory-length/fixtures");

const MODEL = "claude-sonnet-5"; // ClaudeRoute.memoryUpdate.defaultModel
const EFFORT = "medium"; // ClaudeRoute.memoryUpdate.effort
const MAX_TOKENS = 2500; // MemoryUpdateClient.makeRequestBody
// MemoryScope.wordLimit（管理画面が橙で警告する閾値）
const LEARNER_LIMIT = 400;
const CHARACTER_LIMIT = 120;

const apiKey = readFileSync(path.join(ROOT, ".secrets/anthropic-api-key"), "utf8").trim();

/** MemoryAdminView.wordCount と同じ数え方（英数字を含まないトークンは数えない）。 */
const wordCount = (text) =>
  text.split(/\s+/).filter((t) => /[\p{L}\p{N}]/u.test(t)).length;

const lineCount = (text) => text.split("\n").filter((l) => l.trim().length > 0).length;

/** Swift の MemoryUpdateClient.systemPrompt を抽出する（model-eval の extract_prompts.py を流用）。 */
function systemPrompt() {
  const out = path.join(FIXTURES, "extracted");
  // extract_prompts.py は既存ファイルがあると差分を .new に書いて上書きしないので、毎回捨てる
  // （残しておくと Swift を直しても古いプロンプトで測ってしまう）
  rmSync(out, { recursive: true, force: true });
  mkdirSync(out, { recursive: true });
  execFileSync("python3", [
    path.join(ROOT, "tools/model-eval/synthetic/extract_prompts.py"),
    out,
  ]);
  return readFileSync(path.join(out, "system-memory.txt"), "utf8");
}

const SCHEMA = {
  type: "object",
  properties: {
    learner: { type: "string" },
    chobi: { type: "string" },
    naruko: { type: "string" },
  },
  required: ["learner", "chobi", "naruko"],
  additionalProperties: false,
};

const block = (note) => (note && note.trim() ? note.trim() : "(none)");

/** MemoryUpdateClient.makeRequestBody と同じ user メッセージ。 */
const userContent = ({ previous, topic, transcript }) =>
  `Previous memory note about the learner:
${block(previous.learner)}

Previous memory note about Chobi:
${block(previous.chobi)}

Previous memory note about Naruko:
${block(previous.naruko)}

Topic of the session that just ended: ${topic}

Transcript:
${transcript}`;

async function generate({ system, previous, topic, transcript }) {
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": apiKey,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      model: MODEL,
      max_tokens: MAX_TOKENS,
      stream: false,
      output_config: { effort: EFFORT, format: { type: "json_schema", schema: SCHEMA } },
      system: [{ type: "text", text: system, cache_control: { type: "ephemeral" } }],
      messages: [{ role: "user", content: userContent({ previous, topic, transcript }) }],
    }),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}: ${(await res.text()).slice(0, 500)}`);
  const json = await res.json();
  if (json.stop_reason === "refusal") throw new Error("refusal");
  // thinking が有効（sonnet-5 は adaptive 既定）だと content[0] が thinking ブロックになりうる
  const textBlock = json.content.filter((b) => b.type === "text").at(-1);
  if (!textBlock) throw new Error(`text ブロックなし: ${JSON.stringify(json.content).slice(0, 300)}`);
  return { notes: JSON.parse(textBlock.text), usage: json.usage, stop: json.stop_reason };
}

const TOPIC = "Weekend plans";
const TRANSCRIPT = `Learner: Hi again! This weekend I want to go to a new ramen shop in Nakameguro.
Chobi: That sounds lovely, Akira. I finally finished the mystery novel I told you about last time.
Naruko: Ooh, ramen! I went to karaoke on Saturday and my throat still hurts.
Learner: Ha, that is funny. I also plan to clean my apartment, which I have been putting off.
Chobi: Putting it off is very relatable. What made you decide to finally do it this weekend?
Learner: My sister is visiting from Osaka next week, so I have no choice.
Naruko: A deadline is the best motivation! What will you cook for her?
Learner: Probably curry, since it is the one thing I make well. Okay, I should go. Goodbye!`;

const CHARACTER_NOTES = {
  chobi:
    "- Adopted two cats and often mentions how playful they are in the morning.\n" +
    "- Is reading a long mystery novel series and talks about the latest one.",
  naruko:
    "- Goes to karaoke most weekends and always sings too many songs.\n" +
    "- Has been playing the same mobile game for months and is stuck on one stage.",
};

const CASES = {
  bloated: "learner-bloated.txt", // 上限を大きく超えたノート（不具合の再現）
  small: "learner-small.txt", // 普段の 1 セッションぶん（過剰圧縮の回帰）
};

function report(label, notes) {
  const rows = [
    ["learner", notes.learner, LEARNER_LIMIT],
    ["chobi", notes.chobi, CHARACTER_LIMIT],
    ["naruko", notes.naruko, CHARACTER_LIMIT],
  ];
  console.log(`\n===== ${label} =====`);
  for (const [name, text, limit] of rows) {
    const w = wordCount(text ?? "");
    console.log(
      `${name}: ${w} 語 / 上限 ${limit} 語, ${lineCount(text ?? "")} 行${w > limit ? "  ← 超過" : ""}`);
  }
  for (const [name, text] of rows) console.log(`\n--- ${name} ---\n${text}`);
}

const which = process.argv[2] ?? "both";
const system = systemPrompt();
for (const [name, fixture] of Object.entries(CASES)) {
  if (which !== "both" && which !== name) continue;
  const previous = {
    learner: readFileSync(path.join(FIXTURES, fixture), "utf8"),
    ...CHARACTER_NOTES,
  };
  console.log(
    `\n[${name}] 前回の学習者ノート: ${wordCount(previous.learner)} 語 / ${lineCount(previous.learner)} 行`);
  const { notes, usage, stop } = await generate({
    system, previous, topic: TOPIC, transcript: TRANSCRIPT,
  });
  console.log(`stop=${stop} out=${usage.output_tokens}tok`);
  report(name, notes);
}
