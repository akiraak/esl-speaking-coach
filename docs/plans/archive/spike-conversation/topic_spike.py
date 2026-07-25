#!/usr/bin/env python3
"""Phase 3 スパイク: トピック候補生成（structured outputs）+ [end] 制御行の検証。"""
import json
import urllib.request
from pathlib import Path

ROOT = Path("/Users/akiraak/Projects/esl-speaking-coach")
API_KEY = (ROOT / ".secrets/anthropic-api-key").read_text().strip()
SYSTEM = (Path(__file__).parent / "group_system_prompt.txt").read_text()

HEADERS = {
    "x-api-key": API_KEY,
    "anthropic-version": "2023-06-01",
    "content-type": "application/json",
}


def call(body):
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=json.dumps(body).encode(), headers=HEADERS,
    )
    with urllib.request.urlopen(req, timeout=300) as resp:
        return json.loads(resp.read())


TOPIC_PROMPT = """\
You generate conversation topic candidates for "ESL Group", a voice chat app where a Japanese \
adult learner practices spoken English with two AI friends. Generate exactly three topic \
candidates the learner can pick from.

Rules:
- Topics are about everyday life: daily routines, food, travel, work, hobbies, movies, plans, \
small personal stories. Concrete beats abstract.
- Vary the three candidates: different genres, and a mix of easy and slightly challenging.
- Do not repeat or closely resemble any topic in the recent-topics list.
- title: three to six words, natural English, works as a card label.
- hook: one short inviting question or teaser, at most twelve words.
"""

TOPIC_SCHEMA = {
    "type": "object",
    "properties": {
        "topics": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "title": {"type": "string"},
                    "hook": {"type": "string"},
                },
                "required": ["title", "hook"],
                "additionalProperties": False,
            },
        }
    },
    "required": ["topics"],
    "additionalProperties": False,
}


def topic_test():
    print("=== Topic generation (structured outputs) ===")
    past = ["Planning a trip", "Food you can't quit", "Your morning routine"]
    data = call({
        "model": "claude-opus-5",
        "max_tokens": 1024,
        "output_config": {
            "effort": "low",
            "format": {"type": "json_schema", "schema": TOPIC_SCHEMA},
        },
        "system": TOPIC_PROMPT,
        "messages": [{"role": "user", "content": "Recent topics: " + ", ".join(past)}],
    })
    text = next(b["text"] for b in data["content"] if b["type"] == "text")
    for t in json.loads(text)["topics"]:
        print(f"  - {t['title']}  /  {t['hook']}")
    print(f"  [stop={data['stop_reason']} out={data['usage']['output_tokens']}]")


def end_test(user_line, label):
    print(f"\n=== [end] test: {label} ===")
    messages = [
        {"role": "user", "content": "[New topic: Food you can't quit]"},
        {"role": "assistant", "content":
            "Chobi: There's always one food I can't stop eating. For me it's coffee jelly.\n"
            "Naruko: Mine is ramen, obviously!\n"
            "Chobi: What food can you never quit?"},
        {"role": "user", "content": "I like ramen. I eat it every week with my coworker."},
        {"role": "assistant", "content":
            "Naruko: Every week? That's dedication!\n"
            "Chobi: Which ramen shop do you two usually go to?"},
        {"role": "user", "content": user_line},
    ]
    data = call({
        "model": "claude-opus-5",
        "max_tokens": 1024,
        "output_config": {"effort": "low"},
        "system": [{"type": "text", "text": SYSTEM, "cache_control": {"type": "ephemeral"}}],
        "messages": messages,
    })
    text = "".join(b.get("text", "") for b in data["content"] if b["type"] == "text")
    print(f"  >>> User: {user_line}")
    for line in text.splitlines():
        if line.strip():
            print(f"     {line}")
    ended = "[end]" in text
    print(f"  -- [end] detected: {ended}")


if __name__ == "__main__":
    topic_test()
    end_test("Okay, I have to go now. Thank you both, it was fun!", "明確な goodbye (終了すべき)")
    end_test("It's almost lunch time, so I'm getting hungry talking about ramen.",
             "時間への言及だけ (継続すべき)")
    end_test("Hmm, let's stop this topic. Can we talk about something else?",
             "トピック変更希望 (終了すべきでない)")
