#!/usr/bin/env python3
"""会話生成モデル比較: claude-opus-5(現行既定) vs claude-sonnet-5 vs claude-haiku-4-5。

同一シナリオ（開始ターン / recast / 短文回答 / 詰まり救済）をストリーミングで実行し、
- first_sentence: 最初の文が確定するまでの秒数（= TTS 開始可能タイミング、体感レイテンシ）
- total: ターン全文の生成完了までの秒数
- out_tokens: 出力トークン数
を計測する。Haiku 4.5 は output_config.effort 非対応のため送らない。
"""
import json
import time
import urllib.request
from pathlib import Path

from stream_spike import SpeakerSentenceChunker

ROOT = Path("/Users/akiraak/Projects/esl-speaking-coach")
API_KEY = (ROOT / ".secrets/anthropic-api-key").read_text().strip()
SYSTEM = (Path(__file__).parent / "group_system_prompt.txt").read_text()

import sys

ALL_MODELS = [
    ("claude-opus-5", {"output_config": {"effort": "low"}}),
    ("claude-sonnet-5", {"output_config": {"effort": "low"}}),
    ("claude-haiku-4-5", {}),
]
# 引数でモデル名を絞り込める（例: model_compare_spike.py claude-sonnet-5）
MODELS = [(m, e) for m, e in ALL_MODELS if len(sys.argv) < 2 or m in sys.argv[1:]]

# (label, user メッセージ)。会話は各モデル自身の応答でつなぐ
CONVERSATIONS = [
    [
        ("opening: Planning a trip", "[New topic: Planning a trip]"),
        ("recast テスト", "I want to go to Okinawa this summer. I go there last year with my family and it was very fun."),
    ],
    [
        ("opening: Food you can't quit", "[New topic: Food you can't quit]"),
        ("短文回答", "I like ramen."),
        ("詰まり救済", "Hmm... I don't know."),
    ],
]


def stream_turn(model, extra, messages):
    body = {
        "model": model,
        "max_tokens": 1024,
        "stream": True,
        "system": [{"type": "text", "text": SYSTEM, "cache_control": {"type": "ephemeral"}}],
        "messages": messages,
        **extra,
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
    chunker = SpeakerSentenceChunker()
    full = ""
    sentences = []
    stop_reason = None
    out_tokens = None
    t0 = time.monotonic()
    t_first_sentence = None
    with urllib.request.urlopen(req, timeout=300) as resp:
        for raw in resp:
            line = raw.decode("utf-8").strip()
            if not line.startswith("data:"):
                continue
            payload = json.loads(line[5:].strip())
            ptype = payload.get("type")
            if ptype == "content_block_delta" and payload["delta"].get("type") == "text_delta":
                full += payload["delta"]["text"]
                for spk, sent, _ in chunker.consume(payload["delta"]["text"]):
                    if t_first_sentence is None:
                        t_first_sentence = time.monotonic() - t0
                    sentences.append((spk, sent))
            elif ptype == "message_delta":
                stop_reason = payload["delta"].get("stop_reason")
                out_tokens = (payload.get("usage") or {}).get("output_tokens")
    for spk, sent, _ in chunker.flush():
        if t_first_sentence is None:
            t_first_sentence = time.monotonic() - t0
        sentences.append((spk, sent))
    total = time.monotonic() - t0
    return {
        "text": full, "sentences": sentences, "stop": stop_reason,
        "out": out_tokens, "first": t_first_sentence, "total": total,
    }


def main():
    results = {}
    for model, extra in MODELS:
        print(f"\n################ {model} ################")
        rows = []
        for convo in CONVERSATIONS:
            messages = []
            for label, user in convo:
                messages.append({"role": "user", "content": user})
                r = stream_turn(model, extra, messages)
                messages.append({"role": "assistant", "content": r["text"]})
                rows.append((label, r))
                print(f"\n--- {label} [first={r['first']:.2f}s total={r['total']:.2f}s "
                      f"out={r['out']} stop={r['stop']}]")
                print(f"  >>> User: {user}")
                bad = [l for l in r["text"].splitlines()
                       if l.strip() and not l.startswith(("Chobi: ", "Naruko: ", "[end]"))]
                for spk, sent in r["sentences"]:
                    print(f"      {spk}: {sent}")
                if bad:
                    print(f"  !! タグ違反行: {bad}")
        results[model] = rows

    print("\n================ サマリ ================")
    print(f"{'model':<18} {'first_sentence avg':>20} {'total avg':>12} {'out_tokens avg':>16}")
    for model, rows in results.items():
        firsts = [r["first"] for _, r in rows]
        totals = [r["total"] for _, r in rows]
        outs = [r["out"] for _, r in rows if r["out"]]
        print(f"{model:<18} {sum(firsts)/len(firsts):>18.2f}s {sum(totals)/len(totals):>10.2f}s "
              f"{sum(outs)/len(outs):>16.0f}")
        print(f"{'':<18}   per-turn first: " + " ".join(f"{f:.2f}" for f in firsts))


if __name__ == "__main__":
    main()
