'''Swift ソースから system prompt の文字列リテラルを抽出する。

swiftc でビルドすると依存（DiagnosticsLog / ConversationMessage …）が芋づる式に増えるので、
Swift の複数行文字列リテラルだけを直接パースする。規則:
  - 開きの三連引用符の次行から、閉じの三連引用符の直前行までが本文
  - 閉じ側のインデントぶんを各行の先頭から取り除く
  - 行末のバックスラッシュは「改行を出力しない」継続
'''
import re, sys, pathlib

ROOT = pathlib.Path("/Users/akiraak/Projects/esl-speaking-coach")

TARGETS = [
    ("EslSpeakingCoach/Claude/CoachSystemPrompt.swift", "text", "system-conversation.txt"),
    ("EslSpeakingCoach/Claude/WordCoachSystemPrompt.swift", "text", "system-word.txt"),
    ("EslSpeakingCoach/Claude/QuizCoachSystemPrompt.swift", "text", "system-quiz.txt"),
    ("EslSpeakingCoach/Claude/TopicSuggestionClient.swift", "systemPrompt", "system-topic.txt"),
    ("EslSpeakingCoach/Claude/SessionFeedbackClient.swift", "systemPrompt", "system-feedback.txt"),
    ("EslSpeakingCoach/Claude/MemoryUpdateClient.swift", "systemPrompt", "system-memory.txt"),
]


def extract(path: pathlib.Path, name: str) -> str:
    src = path.read_text(encoding="utf-8")
    m = re.search(rf'static let {re.escape(name)}(?::\s*String)?\s*=\s*"""\n', src)
    if not m:
        raise KeyError(f"{name} not found in {path.name}")
    rest = src[m.end():]
    close = re.search(r'\n([ \t]*)"""', rest)
    if not close:
        raise ValueError(f"closing delimiter not found for {name}")
    body = rest[: close.start()]
    indent = close.group(1)

    lines = []
    for line in body.split("\n"):
        lines.append(line[len(indent):] if line.startswith(indent) else line.lstrip())

    out = []
    buffer = ""
    for line in lines:
        if line.endswith("\\"):
            buffer += line[:-1]
        else:
            out.append(buffer + line)
            buffer = ""
    if buffer:
        out.append(buffer)
    text = "\n".join(out)
    # Swift のエスケープを戻す（プロンプト内で使われるのは \" と \\ 程度）
    return text.replace('\\"', '"').replace("\\\\", "\\")


def main(outdir: pathlib.Path):
    outdir.mkdir(parents=True, exist_ok=True)
    for rel, name, filename in TARGETS:
        path = ROOT / rel
        if not path.exists():
            print(f"  skip {rel}（ファイルなし）")
            continue
        try:
            text = extract(path, name)
        except (KeyError, ValueError) as error:
            print(f"  skip {rel}: {error}")
            continue
        dest = outdir / filename
        # 既に swiftc で抽出済みのものがあれば一致を確認する（パーサの検算）
        if dest.exists():
            old = dest.read_text(encoding="utf-8")
            mark = "一致" if old == text else f"不一致（既存 {len(old)} / 抽出 {len(text)}）"
            print(f"  {filename}: {len(text)} 字  [{mark}]")
            if old != text:
                (outdir / (filename + ".new")).write_text(text, encoding="utf-8")
                continue
        else:
            print(f"  {filename}: {len(text)} 字")
        dest.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main(pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "fixtures"))
