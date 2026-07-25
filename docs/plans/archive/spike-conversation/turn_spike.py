#!/usr/bin/env python3
"""台本方式スパイク: 仮トピック 3 個で 2 キャラ会話を仮生成して内容を確認する。

プロジェクト規約 (CLAUDE.md) に合わせる:
- claude-opus-5 / temperature 等なし / effort low / max_tokens 1024
- system prompt は固定文 + cache_control ephemeral
- 本番はストリーミング必須だが、本スパイクは内容確認が目的なので非ストリーミング
"""
import json
import re
import sys
import urllib.request
from pathlib import Path

ROOT = Path("/Users/akiraak/Projects/esl-speaking-coach")
API_KEY = (ROOT / ".secrets/anthropic-api-key").read_text().strip()
SYSTEM = (Path(__file__).parent / "group_system_prompt.txt").read_text()

TAG_RE = re.compile(r"^(Chobi|Naruko): (.+)$")


def call(messages):
    body = {
        "model": "claude-opus-5",
        "max_tokens": 1024,
        "output_config": {"effort": "low"},
        "system": [{"type": "text", "text": SYSTEM, "cache_control": {"type": "ephemeral"}}],
        "messages": messages,
    }
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=json.dumps(body).encode(),
        headers={
            "x-api-key": API_KEY,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=300) as resp:
        data = json.loads(resp.read())
    if data.get("stop_reason") == "refusal":
        return "(refusal)", data
    text = "".join(b.get("text", "") for b in data["content"] if b["type"] == "text")
    return text, data


def show(label, text, data):
    usage = data["usage"]
    print(f"  --- AI ({label}) "
          f"[stop={data['stop_reason']} out={usage['output_tokens']} "
          f"cache_w={usage.get('cache_creation_input_tokens')} cache_r={usage.get('cache_read_input_tokens')}]")
    lines = [l for l in text.splitlines() if l.strip()]
    for line in lines:
        m = TAG_RE.match(line)
        mark = "  " if m else "!!"  # !! = タグ形式違反
        print(f"  {mark} {line}")
    n = sum(1 for l in lines if TAG_RE.match(l))
    limit = 3 if label == "opening" else 2
    if not (1 <= n <= limit):
        print(f"  !! 発話数 {n} (期待 1-{limit})")


SCENARIOS = [
    (
        "Planning a trip",
        [
            "I want to go to Okinawa this summer. I go there last year with my family and it was very fun.",
        ],
    ),
    (
        "Food you can't quit",
        [
            "I like ramen.",
            "Hmm... I don't know.",
        ],
    ),
    (
        "Your morning routine",
        [
            "I wake up at six thirty and I check my phone in the futon. Ah, how to say futon in English?",
        ],
    ),
]


def main():
    for topic, user_turns in SCENARIOS:
        print(f"\n=== Topic: {topic} ===")
        messages = [{"role": "user", "content": f"[New topic: {topic}]"}]
        text, data = call(messages)
        show("opening", text, data)
        messages.append({"role": "assistant", "content": text})
        for u in user_turns:
            print(f"  >>> User: {u}")
            messages.append({"role": "user", "content": u})
            text, data = call(messages)
            show("reply", text, data)
            messages.append({"role": "assistant", "content": text})


if __name__ == "__main__":
    main()
