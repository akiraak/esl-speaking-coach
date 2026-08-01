// Phase 5 Step 1: 実機エクスポート (fixtures/export.json) から評価用 fixture を組み立てる。
// API 形式履歴の再構築は ChatRoomStore.rebuildHistory / SessionOpeningMessage.compose と同一規則、
// フィードバック用 transcript は ChatRoomStore.sessionTranscript と同一規則。
// 制約: セッション当時の記憶ノートは保存されていないため、[Memory:] 行は現在ノートの近似。
import { readFileSync, writeFileSync } from "node:fs";

const dir = new URL(".", import.meta.url).pathname;
const exp = JSON.parse(readFileSync(`${dir}fixtures/export.json`, "utf8"));

const SCRIPT_TAG = { chobi: "Chobi: ", naruko: "Naruko: " };
const DISPLAY = { user: "Learner", chobi: "Chobi", naruko: "Naruko" };
const OPENING_KEY = { conversation: "New topic", word: "New word", quiz: "Quiz words" };
const LEARNER_FIRST_TITLE = "話しかける";

const memoryNote = exp.memoryNote?.trim() || null;
const memoryLine = memoryNote ? `[Memory: ${memoryNote}]` : null;

function isLearnerFirst(session) {
  return session.kind === "conversation" && session.topicTitle === LEARNER_FIRST_TITLE;
}

// SessionOpeningMessage.compose / composeMemoryOnly 相当（usesMemoryNote は conversation のみ）
function openingText(session) {
  if (isLearnerFirst(session)) return memoryLine; // null なら開始メッセージなし
  const topicLine = `[${OPENING_KEY[session.kind]}: ${session.topicTitle}]`;
  if (session.kind === "conversation" && memoryLine) return `${memoryLine}\n${topicLine}`;
  return topicLine;
}

// ChatRoomStore.rebuildHistory 相当
function rebuildHistory(session) {
  const history = [];
  const opening = openingText(session);
  if (opening) history.push({ role: "user", text: opening });
  let pendingScript = [];
  const flush = () => {
    if (!pendingScript.length) return;
    const text = pendingScript.join("\n");
    pendingScript = [];
    if (!history.length) return; // 先頭 assistant は API が受けないため落とす（本番同一）
    history.push({ role: "assistant", text });
  };
  for (const m of session.messages) {
    if (m.speaker === "user") {
      flush();
      const last = history[history.length - 1];
      if (last && last.role === "user") last.text += "\n" + m.text;
      else history.push({ role: "user", text: m.text });
    } else {
      pendingScript.push(SCRIPT_TAG[m.speaker] + m.text);
    }
  }
  flush();
  return history;
}

// ChatRoomStore.sessionTranscript 相当
function transcript(session) {
  const lines = [];
  let learnerTurnCount = 0;
  for (const m of session.messages) {
    lines.push(`${DISPLAY[m.speaker]}: ${m.text}`);
    if (m.speaker === "user") learnerTurnCount += 1;
  }
  return { transcript: lines.join("\n"), learnerTurnCount };
}

const sessions = exp.sessions.map((s) => {
  const { transcript: tr, learnerTurnCount } = transcript(s);
  return {
    id: s.id,
    kind: s.kind,
    topicTitle: s.topicTitle,
    startedAt: s.startedAt,
    endedAt: s.endedAt,
    messageCount: s.messages.length,
    learnerTurnCount,
    history: rebuildHistory(s),
    transcript: tr,
    appFeedback: s.feedback ?? null,
  };
});

writeFileSync(
  `${dir}fixtures/sessions.json`,
  JSON.stringify({ builtAt: exp.exportedAt, memoryNote, sessions }, null, 2),
);

// サマリ出力（ケース選定用）
const byKind = {};
for (const s of sessions) (byKind[s.kind] ??= []).push(s);
for (const [kind, list] of Object.entries(byKind)) {
  console.log(`\n== ${kind} (${list.length} sessions) ==`);
  const sorted = [...list].sort((a, b) => b.learnerTurnCount - a.learnerTurnCount);
  for (const s of sorted.slice(0, 8)) {
    const lastUser = [...s.history].reverse().find((m) => m.role === "user");
    console.log(
      `  ${s.topicTitle} | learnerTurns=${s.learnerTurnCount} msgs=${s.messageCount}` +
      ` fb=${s.appFeedback ? "y" : "-"} | last user: ${(lastUser?.text ?? "").slice(0, 60).replace(/\n/g, " / ")}`,
    );
  }
}
console.log(`\nmemoryNote chars: ${memoryNote?.length ?? 0}`);
