#!/usr/bin/env python3
"""台本方式スパイク Part B: Gemini TTS の発話ごと voice 切替検証。

Chobi=Leda / Naruko=Aoede で英語発話を生成し、レイテンシ計測 + WAV 保存する。
リクエスト形は Swift の GeminiTTSClient と同一（streamGenerateContent SSE, 24kHz PCM16 LE）。
"""
import base64
import json
import time
import urllib.request
import wave
from pathlib import Path

ROOT = Path("/Users/akiraak/Projects/esl-speaking-coach")
API_KEY = (ROOT / ".secrets/gemini-api-key").read_text().strip()
MODEL = "gemini-3.1-flash-tts-preview"
OUT = Path(__file__).parent

STYLES = {
    "Chobi": ("Leda", "Read aloud in a warm, calm, gently cheerful voice, "
                       "like a friendly teacher smiling as she talks:"),
    "Naruko": ("Aoede", "Read aloud in a bright, energetic voice, full of curiosity, "
                        "like an enthusiastic student chatting with friends:"),
}

DIALOGUE = [
    ("Chobi", "Let's talk about trips today. I'm planning a quiet weekend somewhere with good coffee."),
    ("Naruko", "Ooh, I want to go somewhere with great ramen!"),
    ("Chobi", "If you could take a trip next month, where would you go?"),
    ("Naruko", "Yes! A ramen friend! Finally someone understands me."),
]


def tts(speaker, text):
    voice, style = STYLES[speaker]
    body = {
        "contents": [{"parts": [{"text": style + "\n" + text}]}],
        "generationConfig": {
            "responseModalities": ["AUDIO"],
            "speechConfig": {"voiceConfig": {"prebuiltVoiceConfig": {"voiceName": voice}}},
        },
    }
    url = (f"https://generativelanguage.googleapis.com/v1beta/models/{MODEL}"
           f":streamGenerateContent?alt=sse&key={API_KEY}")
    req = urllib.request.Request(
        url, data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    pcm = bytearray()
    t0 = time.monotonic()
    t_first = None
    with urllib.request.urlopen(req, timeout=180) as resp:
        for raw in resp:
            line = raw.decode("utf-8").strip()
            if not line.startswith("data:"):
                continue
            payload = json.loads(line[5:].strip())
            if "error" in payload:
                raise RuntimeError(payload["error"])
            for cand in payload.get("candidates", []):
                for part in (cand.get("content") or {}).get("parts", []):
                    data = (part.get("inlineData") or {}).get("data")
                    if data:
                        if t_first is None:
                            t_first = time.monotonic() - t0
                        pcm.extend(base64.b64decode(data))
    total = time.monotonic() - t0
    return bytes(pcm), t_first, total


def main():
    files = []
    for i, (speaker, text) in enumerate(DIALOGUE, 1):
        pcm, t_first, total = tts(speaker, text)
        dur = len(pcm) / 2 / 24000
        path = OUT / f"tts_{i}_{speaker.lower()}.wav"
        with wave.open(str(path), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(24000)
            w.writeframes(pcm)
        voice = STYLES[speaker][0]
        print(f"{i}. {speaker} ({voice}): first_audio={t_first:.2f}s total={total:.2f}s "
              f"audio_len={dur:.1f}s -> {path.name}")
        files.append(path)
    print("FILES:" + " ".join(str(f) for f in files))


if __name__ == "__main__":
    main()
