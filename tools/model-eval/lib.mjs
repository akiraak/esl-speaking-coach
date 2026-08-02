// Phase 3 実測比較の共通ライブラリ（プロバイダアダプタ + SSE 計測）
import { readFileSync } from "node:fs";

const SECRETS = "/Users/akiraak/Projects/esl-speaking-coach/.secrets";
const readKey = (name) => {
  try {
    return readFileSync(`${SECRETS}/${name}`, "utf8").trim();
  } catch {
    return null; // 使わないプロバイダのキーが無くても他の比較は動かす
  }
};

export const keys = {
  anthropic: readKey("anthropic-api-key"),
  dashscope: readKey("dashscope-api-key"),
  openrouter: readKey("openrouter-api-key"),
  gemini: readKey("gemini-api-key"),
};

// 文末判定: 蓄積テキストに文終端 ([.!?] + 空白/改行/末尾) が現れた最初の時刻を first-sentence とする
function hasSentenceEnd(text) {
  return /[.!?](\s|$)/.test(text);
}

async function* sseLines(res) {
  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buf = "";
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buf += decoder.decode(value, { stream: true });
    let idx;
    while ((idx = buf.indexOf("\n")) >= 0) {
      yield buf.slice(0, idx).replace(/\r$/, "");
      buf = buf.slice(idx + 1);
    }
  }
  if (buf) yield buf;
}

// Anthropic Messages API (本家 / 互換エンドポイント共用)。ストリーミングで計測付き生成。
export async function anthropicStream({
  endpoint = "https://api.anthropic.com/v1/messages",
  apiKey = keys.anthropic,
  model,
  system,
  messages,
  effort,
  maxTokens = 1024,
  format = null, // structured outputs: {type:"json_schema", schema}
  cacheControl = true,
  thinking = null, // 例: {type:"disabled"} — Qwen Anthropic 互換で thinking を切る用
}) {
  const body = {
    model,
    max_tokens: maxTokens,
    stream: true,
    ...(thinking ? { thinking } : {}),
    system: [
      cacheControl
        ? { type: "text", text: system, cache_control: { type: "ephemeral" } }
        : { type: "text", text: system },
    ],
    messages,
  };
  if (effort || format) {
    body.output_config = {};
    if (effort) body.output_config.effort = effort;
    if (format) body.output_config.format = format;
  }
  const t0 = performance.now();
  const res = await fetch(endpoint, {
    method: "POST",
    headers: {
      "x-api-key": apiKey,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`HTTP ${res.status}: ${text.slice(0, 500)}`);
  }
  let text = "";
  let ttft = null;
  let firstSentence = null;
  let stopReason = null;
  const usage = {};
  for await (const line of sseLines(res)) {
    if (!line.startsWith("data:")) continue;
    const json = line.slice(5).trim();
    if (!json) continue;
    let p;
    try { p = JSON.parse(json); } catch { continue; }
    if (p.type === "content_block_delta" && p.delta?.type === "text_delta" && p.delta.text) {
      if (ttft === null) ttft = performance.now() - t0;
      text += p.delta.text;
      if (firstSentence === null && hasSentenceEnd(text)) firstSentence = performance.now() - t0;
    } else if (p.type === "message_start" && p.message?.usage) {
      Object.assign(usage, p.message.usage);
    } else if (p.type === "message_delta") {
      if (p.usage) Object.assign(usage, p.usage);
      if (p.delta?.stop_reason) stopReason = p.delta.stop_reason;
    } else if (p.type === "error") {
      throw new Error(`API error: ${JSON.stringify(p.error)}`);
    }
  }
  return { text, ttft, firstSentence, total: performance.now() - t0, stopReason, usage };
}

// OpenAI Chat Completions 互換 (DashScope compatible-mode / OpenRouter)。
export async function openaiStream({
  baseURL,
  apiKey,
  model,
  system,
  messages,
  maxTokens = 1024,
  extra = {}, // enable_thinking / reasoning / provider / response_format など
  headers = {},
}) {
  const body = {
    model,
    stream: true,
    stream_options: { include_usage: true },
    max_tokens: maxTokens,
    messages: [{ role: "system", content: system }, ...messages],
    ...extra,
  };
  const t0 = performance.now();
  const res = await fetch(`${baseURL}/chat/completions`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${apiKey}`,
      "content-type": "application/json",
      ...headers,
    },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`HTTP ${res.status}: ${text.slice(0, 500)}`);
  }
  let text = "";
  let reasoning = "";
  let ttft = null; // 最初の可視コンテンツ (reasoning は含めない)
  let ttfr = null; // 最初の reasoning トークン (参考)
  let firstSentence = null;
  let finishReason = null;
  let usage = null;
  for await (const line of sseLines(res)) {
    if (!line.startsWith("data:")) continue;
    const json = line.slice(5).trim();
    if (!json || json === "[DONE]") continue;
    let p;
    try { p = JSON.parse(json); } catch { continue; }
    if (p.usage) usage = p.usage;
    const choice = p.choices?.[0];
    if (!choice) continue;
    const delta = choice.delta ?? {};
    const r = delta.reasoning_content ?? delta.reasoning;
    if (r) {
      if (ttfr === null) ttfr = performance.now() - t0;
      reasoning += r;
    }
    if (delta.content) {
      if (ttft === null) ttft = performance.now() - t0;
      text += delta.content;
      if (firstSentence === null && hasSentenceEnd(text)) firstSentence = performance.now() - t0;
    }
    if (choice.finish_reason) finishReason = choice.finish_reason;
  }
  return { text, reasoning, ttft, ttfr, firstSentence, total: performance.now() - t0, finishReason, usage };
}

// Gemini API（Gemma 4 の評価用。Anthropic / OpenAI いずれとも形が違うので専用アダプタ）。
// - system prompt は systemInstruction、structured outputs は
//   generationConfig.responseMimeType + responseJsonSchema
// - streamGenerateContent?alt=sse で SSE が返る（返却形は anthropicStream と揃える）
// - Gemma には effort / thinking / プロンプトキャッシュの概念が無いので引数も持たない
export async function geminiStream({
  apiKey = keys.gemini,
  model,
  system,
  messages, // Anthropic 形式 [{role:"user"|"assistant", content}] を contents へ変換する
  maxTokens = 1024,
  schema = null,
}) {
  const body = {
    contents: messages.map((m) => ({
      role: m.role === "assistant" ? "model" : "user",
      parts: [{ text: typeof m.content === "string" ? m.content : String(m.content) }],
    })),
    generationConfig: {
      maxOutputTokens: maxTokens,
      ...(schema
        ? { responseMimeType: "application/json", responseJsonSchema: schema }
        : {}),
    },
  };
  if (system) body.systemInstruction = { parts: [{ text: system }] };

  const endpoint =
    `https://generativelanguage.googleapis.com/v1beta/models/${model}:streamGenerateContent?alt=sse`;
  const t0 = performance.now();
  const res = await fetch(endpoint, {
    method: "POST",
    headers: { "x-goog-api-key": apiKey, "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`HTTP ${res.status}: ${text.slice(0, 500)}`);
  }
  let text = "";
  let ttft = null;
  let firstSentence = null;
  let finishReason = null;
  let usage = {};
  for await (const line of sseLines(res)) {
    if (!line.startsWith("data:")) continue;
    const json = line.slice(5).trim();
    if (!json) continue;
    let p;
    try { p = JSON.parse(json); } catch { continue; }
    if (p.error) throw new Error(`API error: ${JSON.stringify(p.error)}`);
    const candidate = p.candidates?.[0];
    for (const part of candidate?.content?.parts ?? []) {
      if (typeof part.text !== "string" || !part.text) continue;
      if (ttft === null) ttft = performance.now() - t0;
      text += part.text;
      if (firstSentence === null && hasSentenceEnd(text)) firstSentence = performance.now() - t0;
    }
    if (candidate?.finishReason) finishReason = candidate.finishReason;
    if (p.usageMetadata) usage = p.usageMetadata;
  }
  // usage のキー名を Anthropic 側と揃えて集計しやすくする（課金は無料枠だがトークン数は見る）
  const normalized = {
    input_tokens: usage.promptTokenCount ?? null,
    output_tokens: usage.candidatesTokenCount ?? null,
    total_tokens: usage.totalTokenCount ?? null,
  };
  return {
    text, ttft, firstSentence, total: performance.now() - t0,
    stopReason: finishReason, usage: normalized,
  };
}

// Anthropic 非ストリーミング（opus-5 判定用。structured outputs で JSON を受ける）
export async function anthropicJudge({ system, messages, schema, model = "claude-opus-5", maxTokens = 8000 }) {
  const body = {
    model,
    max_tokens: maxTokens,
    system: [{ type: "text", text: system, cache_control: { type: "ephemeral" } }],
    messages,
    output_config: { effort: "high", format: { type: "json_schema", schema } },
  };
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": keys.anthropic,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}: ${(await res.text()).slice(0, 500)}`);
  const data = await res.json();
  if (data.stop_reason === "refusal") throw new Error("judge refusal");
  const text = data.content.find((b) => b.type === "text")?.text ?? "";
  return { result: JSON.parse(text), usage: data.usage };
}

export function median(nums) {
  const s = [...nums].filter((n) => n != null).sort((a, b) => a - b);
  if (!s.length) return null;
  const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
