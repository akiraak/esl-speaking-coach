// Phase 5 Step 2: fixtures/sessions.json (実データ) から評価ケースを組み立てる → fixtures/cases5.json
// 各ケース = 実セッションの再構築履歴の prefix (user ターンで終わる)。次の assistant ターンを生成させる。
// goodbye だけ実データに無いため、実履歴の assistant ターン終わり prefix に合成 user ターンを接ぐ。
import { readFileSync, writeFileSync } from "node:fs";

const dir = new URL(".", import.meta.url).pathname;
const { sessions } = JSON.parse(readFileSync(`${dir}fixtures/sessions.json`, "utf8"));

const byTitle = (kind, title, minMsgs = 0) =>
  sessions.find((s) => s.kind === kind && s.topicTitle === title && s.messageCount >= minMsgs);

// prefix: history[0..endIndex] (endIndex は user ターン)。API 形式 messages に変換
const prefix = (s, endIndex) => {
  if (s.history[endIndex].role !== "user") throw new Error(`${s.topicTitle}#${endIndex} is not user`);
  return s.history.slice(0, endIndex + 1).map((m) => ({ role: m.role, content: m.text }));
};
// assistant 終わりの prefix + 合成 user ターン
const withSynthetic = (s, endAssistantIndex, text) => {
  if (s.history[endAssistantIndex].role !== "assistant")
    throw new Error(`${s.topicTitle}#${endAssistantIndex} is not assistant`);
  return [
    ...s.history.slice(0, endAssistantIndex + 1).map((m) => ({ role: m.role, content: m.text })),
    { role: "user", content: text },
  ];
};

const ai = byTitle("conversation", "AIが友達になる日");
const game = byTitle("conversation", "好きなゲームのやり方");
const sports = byTitle("conversation", "観るスポーツ派?やる派?");
const jobs = byTitle("conversation", "もしも仕事を変えたら");
const freetalk = sessions.find((s) => s.kind === "conversation" && s.topicTitle === "Free talk" && s.messageCount === 19);
const morning = byTitle("conversation", "Morning vs Night Person");
const fail = byTitle("conversation", "人前で失敗したら");
const nap = byTitle("conversation", "昼寝するか耐えるか");
const childhood = byTitle("conversation", "子供の頃の遊び方");
const talkFirst = sessions.find((s) => s.kind === "conversation" && s.topicTitle === "話しかける" && s.messageCount === 20);

// 深い位置の内容のある user ターンを探す (単語数 >= minWords, index >= minIndex)
function deepUserIndex(s, { minWords = 6, minIndex = 16 } = {}) {
  for (let i = s.history.length - 1; i >= minIndex; i--) {
    const m = s.history[i];
    if (m.role === "user" && m.text.trim().split(/\s+/).length >= minWords) return i;
  }
  throw new Error(`no deep user turn in ${s.topicTitle}`);
}
// 末尾側の assistant index
function lastAssistantIndex(s) {
  for (let i = s.history.length - 1; i >= 0; i--) if (s.history[i].role === "assistant") return i;
  throw new Error("no assistant turn");
}

// expectEnd: "no" = [end] を出したら違反 / "yes" = 出さなければ違反 / "optional" = どちらも許容
const conversation = [
  { id: "continue-early", note: "序盤の通常ターン (実: AIが友達になる日 #2)", s: ai, messages: prefix(ai, 2) },
  { id: "continue-long", note: "20 項超の深い実履歴での通常ターン (実: 好きなゲームのやり方)", s: game, messages: prefix(game, deepUserIndex(game)) },
  { id: "continue-oneword", note: "一語返答 Baseball への継続 (実: 観るスポーツ派 #16)", s: sports, messages: prefix(sports, 16) },
  { id: "continue-sttnoise", note: "STT ノイズ (中盤に突然 Hello.) への継続 (実: もしも仕事を変えたら #12)", s: jobs, messages: prefix(jobs, 12) },
  { id: "continue-question", note: "学習者からの質問返し (実: Free talk #16)", s: freetalk, messages: prefix(freetalk, 16) },
  { id: "goodbye-explicit", note: "明示的な別れの挨拶 (実履歴 + 合成)", s: fail, expectEnd: "yes",
    messages: withSynthetic(fail, lastAssistantIndex(fail), "This was fun. I have to go now. Goodbye, see you!") },
  { id: "goodbye-ambiguous", note: "曖昧な終わりの合図 (実履歴 + 合成)", s: nap, expectEnd: "optional", checkLastQuestion: false,
    messages: withSynthetic(nap, lastAssistantIndex(nap), "Hmm, it is getting late. Maybe I should think about dinner soon.") },
  { id: "japanese-full", note: "全文日本語入力 (実: Free talk #2 え、なんだこれ。)", s: freetalk, messages: prefix(freetalk, 2) },
  { id: "japanese-mixed", note: "日英混在入力 (実: Morning vs Night #20)", s: morning, messages: prefix(morning, 20) },
  { id: "newtopic-memory", note: "記憶ノート付き開幕ターン (実: 子供の頃の遊び方 #0)", s: childhood, topicOpening: true, messages: prefix(childhood, 0) },
  { id: "learnerfirst-open", note: "話しかける開幕 ([Memory]+学習者第一声) (実: 話しかける #0)", s: talkFirst, topicOpening: true, messages: prefix(talkFirst, 0) },
].map(({ s, ...c }) => ({
  topicOpening: false, expectEnd: "no", checkLastQuestion: c.expectEnd !== "yes", system: "conversation",
  source: { sessionId: s.id, topicTitle: s.topicTitle }, ...c,
}));

// 単語・クイズ (形式チェック中心)。word は [end] 規定なし → 常に "no"。
const wordInv = sessions.find((s) => s.kind === "word" && s.topicTitle === "involves" && s.messageCount === 29);
const wordForm = sessions.find((s) => s.kind === "word" && s.topicTitle === "form");
const quiz5 = sessions.find((s) => s.kind === "quiz" && s.topicTitle.includes(","));
const quizAnx = sessions.find((s) => s.kind === "quiz" && s.topicTitle === "anxiety" && s.messageCount === 15);

const wordquiz = [
  { id: "word-open", note: "単語モード開幕 [New word: form]", system: "word", topicOpening: true, s: wordForm, messages: prefix(wordForm, 0) },
  { id: "word-continue", note: "単語モード中盤の継続 (実: involves)", system: "word", s: wordInv, messages: prefix(wordInv, deepUserIndex(wordInv, { minWords: 4, minIndex: 10 })) },
  { id: "quiz-continue", note: "5 語クイズの中盤 (実: chronically ほか)", system: "quiz", s: quiz5, messages: prefix(quiz5, deepUserIndex(quiz5, { minWords: 4, minIndex: 10 })) },
  { id: "quiz-end", note: "1 語クイズの最終解答後 → 締めて [end] (実: anxiety)", system: "quiz", expectEnd: "yes", s: quizAnx,
    messages: prefix(quizAnx, quizAnx.history.length - 2 + (quizAnx.history.at(-1).role === "user" ? 1 : 0)) },
].map(({ s, ...c }) => ({
  topicOpening: false, expectEnd: "no", checkLastQuestion: c.expectEnd !== "yes",
  source: { sessionId: s.id, topicTitle: s.topicTitle }, ...c,
}));

// フィードバック: 実 transcript 4 本 (会話 3 + 単語 1。文体・長さ・ノイズ量が異なるもの)
const giveup = sessions.find((s) => s.kind === "word" && s.topicTitle === "Give up" && s.messageCount === 37);
const feedback = [game, morning, fail, giveup].map((s) => ({
  id: `fb-${s.topicTitle.replace(/\s+/g, "-").toLowerCase()}`,
  topic: s.topicTitle, kind: s.kind, learnerTurnCount: s.learnerTurnCount,
  transcript: s.transcript, appFeedback: s.appFeedback,
  source: { sessionId: s.id },
}));

// マルチターン再生: 学習者発話固定で AI ターンのみ再生成する対象セッション
const replay = [ai, morning].map((s) => ({
  id: `replay-${s.topicTitle === "AIが友達になる日" ? "ai" : "morning"}`,
  topic: s.topicTitle, source: { sessionId: s.id },
  history: s.history, // [0]=opening user。user ターンを固定し assistant を差し替えていく
}));

const out = { builtAt: new Date().toISOString(), conversation, wordquiz, feedback, replay };
writeFileSync(`${dir}fixtures/cases5.json`, JSON.stringify(out, null, 2));

for (const c of [...conversation, ...wordquiz]) {
  const last = c.messages.at(-1);
  console.log(`[${c.id}] sys=${c.system} msgs=${c.messages.length} end=${c.expectEnd} open=${c.topicOpening}`);
  console.log(`   last user: ${last.content.slice(0, 100).replace(/\n/g, " / ")}`);
}
console.log(`\nfeedback: ${feedback.map((f) => `${f.id}(${f.learnerTurnCount}t)`).join(", ")}`);
console.log(`replay: ${replay.map((r) => `${r.id}(${r.history.length} items)`).join(", ")}`);
