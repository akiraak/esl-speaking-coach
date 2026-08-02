// 合成セッション（synthetic/export.json → fixtures/sessions.json）から評価ケースを組み立てる。
// 実機の書き出しが無くても Phase 2 / 3 を回すためのもの。ケースの意図は Phase 5 の
// build_cases.mjs（実データ版）と揃えてある。
import { readFileSync, writeFileSync } from "node:fs";

const dir = new URL(".", import.meta.url).pathname;
const { sessions, memoryNote } = JSON.parse(readFileSync(`${dir}fixtures/sessions.json`, "utf8"));

const byTitle = (title) => {
  const s = sessions.find((x) => x.topicTitle === title);
  if (!s) throw new Error(`session not found: ${title}`);
  return s;
};

// prefix: history[0..endIndex]（endIndex は user ターン）。API 形式 messages に変換
const prefix = (s, endIndex) => {
  if (s.history[endIndex].role !== "user") {
    throw new Error(`${s.topicTitle}#${endIndex} is not user (${s.history[endIndex].role})`);
  }
  return s.history.slice(0, endIndex + 1).map((m) => ({ role: m.role, content: m.text }));
};

// assistant 終わりの prefix + 合成 user ターン（別れの挨拶などを継ぎ足す用）
const withSynthetic = (s, endAssistantIndex, text) => {
  if (s.history[endAssistantIndex].role !== "assistant") {
    throw new Error(`${s.topicTitle}#${endAssistantIndex} is not assistant`);
  }
  return [
    ...s.history.slice(0, endAssistantIndex + 1).map((m) => ({ role: m.role, content: m.text })),
    { role: "user", content: text },
  ];
};

const weekend = byTitle("週末の失敗談");
const morning = byTitle("朝型か夜型か");
const moving = byTitle("もし引っ越すなら");
const word = byTitle("put off");

// user ターンの index を探す（n 番目の user ターン。0 始まり）
const userIndex = (s, n) => {
  let count = 0;
  for (let i = 0; i < s.history.length; i++) {
    if (s.history[i].role === "user" && i > 0) {
      if (count === n) return i;
      count++;
    }
  }
  throw new Error(`no user turn #${n} in ${s.topicTitle}`);
};
const lastAssistantIndex = (s) => {
  for (let i = s.history.length - 1; i >= 0; i--) if (s.history[i].role === "assistant") return i;
  throw new Error("no assistant turn");
};

// expectEnd: "no" = [end] を出したら違反 / "yes" = 出さなければ違反 / "optional" = どちらも許容
const conversation = [
  { id: "continue-early", note: "序盤の通常ターン（週末の失敗談・1 個目の学習者発話）",
    s: weekend, messages: prefix(weekend, userIndex(weekend, 0)) },
  { id: "continue-oneword", note: "一語返答 \"Bread.\" への継続",
    s: weekend, messages: prefix(weekend, userIndex(weekend, 1)) },
  { id: "continue-deep", note: "15 項の深い履歴での通常ターン（もし引っ越すなら）",
    s: moving, messages: prefix(moving, userIndex(moving, 6)) },
  { id: "continue-sttnoise", note: "STT ノイズ（中盤に突然 \"Hello.\"）が直前の発話",
    s: morning, messages: prefix(morning, userIndex(morning, 3)) },
  { id: "continue-question", note: "学習者からの語学質問（引っ越し は英語で？）が直前の発話",
    s: moving, messages: prefix(moving, userIndex(moving, 5)) },
  { id: "japanese-mixed", note: "日英混在入力（えっと、SF movie…）が直前の発話",
    s: morning, messages: prefix(morning, userIndex(morning, 5)) },
  { id: "goodbye-explicit", note: "明示的な別れの挨拶 → [end] を出すべき",
    s: moving, expectEnd: "yes", messages: prefix(moving, userIndex(moving, 8)) },
  { id: "goodbye-ambiguous", note: "曖昧な終わりの合図（そろそろ夕飯…）→ [end] を出すべきでない",
    s: morning, expectEnd: "optional", checkLastQuestion: false,
    messages: prefix(morning, userIndex(morning, 7)) },
  { id: "newtopic-memory", note: "記憶ノート付きのトピック開幕ターン",
    s: weekend, topicOpening: true, messages: [
      { role: "user", content: `[Memory: ${memoryNote}]\n[New topic: 子供の頃の遊び方]` },
    ] },
  { id: "learnerfirst-open", note: "「話しかける」開幕（[Memory] + 学習者の第一声）",
    s: weekend, topicOpening: true, messages: [
      { role: "user", content: `[Memory: ${memoryNote}]` },
      { role: "user", content: "Hello. Today I am little tired but I want to talk." },
    ] },
].map(({ s, ...c }) => ({
  topicOpening: false, expectEnd: "no", checkLastQuestion: c.expectEnd !== "yes",
  system: "conversation", source: { sessionId: s.id, topicTitle: s.topicTitle }, ...c,
}));

const wordquiz = [
  { id: "word-open", note: "単語モード開幕 [New word: put off]", system: "word", topicOpening: true,
    s: word, messages: [{ role: "user", content: "[New word: put off]" }] },
  { id: "word-continue", note: "単語モード中盤の継続（過去形の作文後）", system: "word",
    s: word, messages: prefix(word, userIndex(word, 5)) },
].map(({ s, ...c }) => ({
  topicOpening: false, expectEnd: "no", checkLastQuestion: c.expectEnd !== "yes",
  source: { sessionId: s.id, topicTitle: s.topicTitle }, ...c,
}));

// フィードバック: 合成 transcript 4 本（会話 3 + 単語 1）
const feedback = [weekend, morning, moving, word].map((s) => ({
  id: `fb-${s.id.slice(0, 4)}`,
  topic: s.topicTitle, kind: s.kind, learnerTurnCount: s.learnerTurnCount,
  transcript: s.transcript, appFeedback: null,
  source: { sessionId: s.id },
}));

// マルチターン再生: 学習者発話を固定し AI ターンだけを各モデルで再生成する
const replay = [weekend, morning].map((s) => ({
  id: `replay-${s.topicTitle === "週末の失敗談" ? "weekend" : "morning"}`,
  topicTitle: s.topicTitle,
  opening: s.history[0].text, // [Memory: ...]\n[New topic: ...]
  learnerTurns: s.history.filter((m, i) => m.role === "user" && i > 0).map((m) => m.text),
  source: { sessionId: s.id },
}));

const cases = { conversation, wordquiz, feedback, replay, memoryNote };
writeFileSync(`${dir}fixtures/cases-synth.json`, JSON.stringify(cases, null, 2));

console.log("== conversation ==");
for (const c of conversation) {
  const last = c.messages.at(-1);
  console.log(`  ${c.id.padEnd(20)} msgs=${String(c.messages.length).padStart(2)} expectEnd=${c.expectEnd.padEnd(8)} last user: ${last.content.slice(0, 56).replace(/\n/g, " / ")}`);
}
console.log("== wordquiz ==");
for (const c of wordquiz) console.log(`  ${c.id.padEnd(20)} msgs=${c.messages.length}`);
console.log("== feedback ==");
for (const c of feedback) console.log(`  ${c.id.padEnd(20)} ${c.topic} learnerTurns=${c.learnerTurnCount} chars=${c.transcript.length}`);
console.log("== replay ==");
for (const c of replay) console.log(`  ${c.id.padEnd(20)} ${c.topicTitle} learnerTurns=${c.learnerTurns.length}`);
