#!/usr/bin/env python3
"""台本方式スパイク Part A: ストリーミング途中の speaker タグパース検証。

Claude SSE のデルタを逐次受け取り、SentenceChunker の speaker 対応版（Python 移植）で
「(speaker, 文)」を文確定ごとに取り出せるか・最初の文が何秒で確定するかを測る。
タグがデルタ境界で分割されても壊れないことを確認する。
"""
import json
import re
import time
import urllib.request
from pathlib import Path

ROOT = Path("/Users/akiraak/Projects/esl-speaking-coach")
API_KEY = (ROOT / ".secrets/anthropic-api-key").read_text().strip()
SYSTEM = (Path(__file__).parent / "group_system_prompt.txt").read_text()

TAG_RE = re.compile(r"^(Chobi|Naruko): ")
CLOSING = set('"\'）)]』」')


class SpeakerSentenceChunker:
    """行頭タグで speaker を確定し、文単位で (speaker, sentence) を吐き出す。

    Swift 側の SentenceChunker の境界規則を踏襲:
    - . ! ? （閉じ記号が続いてもよい）の次が空白なら文境界
    - 改行は発話（行）境界 = 文境界 + speaker リセット
    - バッファ末尾の終端記号は境界にしない
    """

    def __init__(self):
        self.line = ""          # 現在行のバッファ
        self.speaker = None     # 現在行の speaker（タグ確定後）
        self.pending = ""       # タグ確定後の本文バッファ

    def consume(self, delta):
        out = []
        for ch in delta:
            if ch == "\n":
                rest = self.pending.strip()
                if self.speaker and rest:
                    out.append((self.speaker, rest, "flush"))
                elif not self.speaker and self.line.strip():
                    out.append(("UNTAGGED", self.line.strip(), "flush"))
                self.line = ""
                self.speaker = None
                self.pending = ""
                continue
            self.line += ch
            if self.speaker is None:
                m = TAG_RE.match(self.line)
                if m:
                    self.speaker = m.group(1)
                    self.pending = self.line[m.end():]
                continue
            self.pending += ch
            out.extend(self._extract())
        return out

    def _extract(self):
        out = []
        while True:
            s = self._next_sentence()
            if s is None:
                return out
            out.append((self.speaker, s, "mid"))

    def _next_sentence(self):
        chars = self.pending
        i = 0
        while i < len(chars):
            c = chars[i]
            if c in ".!?":
                j = i + 1
                while j < len(chars) and chars[j] in CLOSING:
                    j += 1
                if j < len(chars) and chars[j].isspace():
                    sentence = chars[:j].strip()
                    self.pending = chars[j + 1:].lstrip()
                    return sentence if any(ch.isalnum() for ch in sentence) else None
                i = j
                continue
            i += 1
        return None

    def flush(self):
        rest = self.pending.strip()
        if self.speaker and rest:
            return [(self.speaker, rest, "flush")]
        if not self.speaker and self.line.strip():
            return [("UNTAGGED", self.line.strip(), "flush")]
        return []


def stream_turn(messages, label):
    body = {
        "model": "claude-opus-5",
        "max_tokens": 1024,
        "stream": True,
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
    print(f"\n=== {label} ===")
    chunker = SpeakerSentenceChunker()
    full = ""
    n_deltas = 0
    t0 = time.monotonic()
    t_first_delta = None
    t_first_sentence = None
    with urllib.request.urlopen(req, timeout=300) as resp:
        for raw in resp:
            line = raw.decode("utf-8").strip()
            if not line.startswith("data:"):
                continue
            payload = json.loads(line[5:].strip())
            if payload.get("type") != "content_block_delta":
                continue
            delta = payload["delta"]
            if delta.get("type") != "text_delta":
                continue
            text = delta["text"]
            n_deltas += 1
            if t_first_delta is None:
                t_first_delta = time.monotonic() - t0
            full += text
            for speaker, sentence, kind in chunker.consume(text):
                t = time.monotonic() - t0
                if t_first_sentence is None:
                    t_first_sentence = t
                print(f"  [{t:5.2f}s] {speaker}: {sentence}")
    for speaker, sentence, kind in chunker.flush():
        t = time.monotonic() - t0
        if t_first_sentence is None:
            t_first_sentence = t
        print(f"  [{t:5.2f}s] {speaker}: {sentence} (flush)")
    total = time.monotonic() - t0
    print(f"  -- deltas={n_deltas} first_delta={t_first_delta:.2f}s "
          f"first_sentence={t_first_sentence:.2f}s total={total:.2f}s")
    return full


def main():
    messages = [{"role": "user", "content": "[New topic: Planning a trip]"}]
    opening = stream_turn(messages, "opening (streaming)")
    messages.append({"role": "assistant", "content": opening})
    messages.append({
        "role": "user",
        "content": "I want to go to Okinawa this summer. I go there last year with my family and it was very fun.",
    })
    stream_turn(messages, "reply (streaming)")


if __name__ == "__main__":
    main()
