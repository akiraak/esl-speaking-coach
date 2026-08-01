// 機械チェック (Phase 3 checks.mjs の checkTurn を 3 状態 expectEnd に拡張した共通モジュール)
// expectEnd: "no" = [end] を出したら違反 / "yes" = 出さなければ違反 / "optional" = どちらも許容

const PINYIN = /[āáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜ]/;
const CJK = /[぀-ヿ㐀-鿿豈-﫿]/; // かな + 漢字 (中国語簡体字含む)

export function checkTurn(text, { topicOpening = false, expectEnd = "no", checkLastQuestion = true } = {}) {
  const issues = [];
  const rawLines = text.split("\n");
  const lines = rawLines.map((l) => l.trim()).filter((l) => l.length > 0);
  if (rawLines.some((l, i) => l.trim() === "" && i < rawLines.length - 1 && rawLines.slice(i + 1).some((x) => x.trim())))
    issues.push("空行が混ざる");
  const endLineIdx = lines.findIndex((l) => l === "[end]");
  const utterLines = lines.filter((l) => l !== "[end]");
  const untagged = utterLines.filter((l) => !/^(Chobi|Naruko): /.test(l));
  if (untagged.length) issues.push(`タグ無し行 ${untagged.length} 件: "${untagged[0].slice(0, 60)}"`);
  const maxUtter = topicOpening ? 3 : 2;
  if (utterLines.length > maxUtter) issues.push(`発話 ${utterLines.length} 行 (上限 ${maxUtter})`);
  if (CJK.test(text)) issues.push("CJK 文字(日本語/中国語)混入");
  if (PINYIN.test(text)) issues.push("ピンイン声調符号混入");
  if (/[*_#`•\-]\s|\p{Extended_Pictographic}/u.test(text)) issues.push("markdown/絵文字らしき記号");
  const ended = endLineIdx !== -1;
  if (expectEnd === "yes" && !ended) issues.push("[end] が出ていない");
  if (expectEnd === "no" && ended) issues.push("[end] を誤って出力");
  if (ended && endLineIdx !== lines.length - 1) issues.push("[end] が最終行でない");
  if (checkLastQuestion && !ended && expectEnd !== "yes") {
    const last = utterLines.at(-1) ?? "";
    if (!/\?"?$/.test(last)) issues.push("最終行が質問で終わらない");
    const earlierQuestions = utterLines.slice(0, -1).filter((l) => /\?$/.test(l.replace(/^(Chobi|Naruko): /, "")));
    // 修辞的な短い反応は許容 → 9 語以上の疑問文のみ違反として数える (Phase 3 同一)
    const hardQuestions = earlierQuestions.filter((l) => l.split(/\s+/).length >= 9);
    if (hardQuestions.length) issues.push(`最終行以外に長い疑問文 ${hardQuestions.length} 件`);
  }
  return issues;
}

// 致命的違反 (台本パーサ破壊・仕様の明確な破り) の判定。率の比較はこの部分集合で行う
export function isCritical(issue) {
  return /タグ無し行|\[end\]|CJK|ピンイン|発話 \d+ 行/.test(issue);
}
