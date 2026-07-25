#!/usr/bin/env python3
"""トピック生成を claude-sonnet-5 で確認する。"""
import json
import time
import topic_spike as t

past = ["Planning a trip", "Food you can't quit", "Your morning routine"]
t0 = time.monotonic()
data = t.call({
    "model": "claude-sonnet-5",
    "max_tokens": 1024,
    "output_config": {"effort": "low", "format": {"type": "json_schema", "schema": t.TOPIC_SCHEMA}},
    "system": t.TOPIC_PROMPT,
    "messages": [{"role": "user", "content": "Recent topics: " + ", ".join(past)}],
})
elapsed = time.monotonic() - t0
text = next(b["text"] for b in data["content"] if b["type"] == "text")
for topic in json.loads(text)["topics"]:
    print(f"  - {topic['title']}  /  {topic['hook']}")
print(f"  [model=claude-sonnet-5 stop={data['stop_reason']} "
      f"out={data['usage']['output_tokens']} time={elapsed:.2f}s]")
