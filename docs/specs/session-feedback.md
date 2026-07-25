# セッション後フィードバック

2026-07-25 実装（タスク「セッション後のフィードバック生成」。経緯は `docs/plans/archive/session-feedback.md`）。
画面上の位置づけは [screen-layout.md](screen-layout.md) のフィードバックカード。

## 概要

会話中はターン制のため音声レベルの発音指摘をしない方針（CLAUDE.md）。その代わりに、
セッション終了後に会話全文を `claude-opus-5` で評価し、テキストベースのフィードバックカードを
タイムラインへ投稿する。

- **書き手**: Chobi（先生キャラ）。総評は英語でキャラ性を保ち、訂正・表現の解説は日本語
  （学習効率優先。English-only ルールは会話ターンにのみ適用し、セッション後のメタ学習
  コンテンツには適用しない）
- **評価対象**: 学習者の発話のみ。STT 経由のため、誤認識らしきもの（文脈に合わない同音語等）は
  訂正対象にしない

## 生成タイミングとスキップ条件

1. セッション正常終了（手動「トピックを終える」/ goodbye `[end]`）
2. フィードバックカードを**生成中表示で即投稿** → 直後に次のトピックカードを投稿
   （生成完了を待たずに次のトピックを選べる）
3. 生成完了でカード内容に置き換え。失敗時はカード内にエラー + 「もう一度生成」ボタン
   （リトライ用に会話全文のスナップショットをカードが保持する）

- **スキップ**: 学習者の発話（user メッセージ）が 2 未満のセッションは生成せず、
  システムメッセージ「発話が少なかったためフィードバックは省略しました」を出す
- 致命的エラーでセッションが落ちた場合（正常終了でない場合）は投稿しない

## API 呼び出し

CLAUDE.md「フィードバック生成（会話後）」の規約に従う。

- モデル `claude-opus-5` / **ストリーミング**（SSE のテキストデルタを蓄積し、終了後に JSON を
  パース。長い生成でも接続が切れにくい） / `output_config: {"effort": "high", "format": ...}` /
  `max_tokens: 16000`
- structured outputs（下記スキーマ）で出力形式を固定。`stop_reason` を確認し、
  `refusal` は content を読む前にエラーへ
- system prompt は付録の固定英文 + `cache_control`。user メッセージに
  `Topic: <トピック名>` + 話者ラベル付き会話全文（`Learner:` / `Chobi:` / `Naruko:`）を渡す

## 出力構造

| フィールド | 内容 |
| --- | --- |
| `summary` | Chobi の総評。英語 2〜3 文（具体的に良かった点 + 次の課題 1 つ。挨拶・質問なし） |
| `corrections[]` | `original`（発話の該当部分）/ `improved`（自然な言い方）/ `note`（日本語 40 字以内の解説）。最大 5 件・有用な順。理解を妨げるエラー・繰り返したエラー優先。無ければ少なくてよい（捏造禁止） |
| `try_phrases[]` | `phrase`（次に使ってみたい英語表現）/ `meaning`（日本語の意味）。2〜3 件 |

JSON Schema（`output_config.format`）:

```json
{
  "type": "json_schema",
  "schema": {
    "type": "object",
    "properties": {
      "summary": {"type": "string"},
      "corrections": {
        "type": "array",
        "items": {
          "type": "object",
          "properties": {
            "original": {"type": "string"},
            "improved": {"type": "string"},
            "note": {"type": "string"}
          },
          "required": ["original", "improved", "note"],
          "additionalProperties": false
        }
      },
      "try_phrases": {
        "type": "array",
        "items": {
          "type": "object",
          "properties": {
            "phrase": {"type": "string"},
            "meaning": {"type": "string"}
          },
          "required": ["phrase", "meaning"],
          "additionalProperties": false
        }
      }
    },
    "required": ["summary", "corrections", "try_phrases"],
    "additionalProperties": false
  }
}
```

## カードレイアウト

白カード + 枠 + 影（トピックカードと同系。案 D パレット）。

```
┌──────────────────────────┐
│ 📝 Session Feedback       │ ← アクセント色
│ <トピック名>               │ ← 名前ラベル色
│ <summary（英語・Chobi）>   │
│ 直したい表現               │
│ ┌──────────────────────┐ │
│ │ ✗ original            │ │ ← ✗ は liveText 色
│ │ ✓ improved            │ │ ← ✓ は feedbackGood（緑）
│ │   note（日本語）        │ │
│ └──────────────────────┘ │
│ 使ってみたい表現           │
│ ┌──────────────────────┐ │
│ │ phrase                │ │
│ │ meaning（日本語）       │ │
│ └──────────────────────┘ │
└──────────────────────────┘
```

- 生成中: ProgressView + 「Chobi がフィードバックを書いています…」
- 失敗時: エラーメッセージ + 「もう一度生成」ボタン

## 関連ファイル

- `EslSpeakingCoach/Claude/SessionFeedbackClient.swift` — API クライアント（プロンプト・スキーマ含む）
- `EslSpeakingCoach/Conversation/ChatRoomStore.swift` — 投稿フロー・スキップ条件・リトライ
- `EslSpeakingCoach/Conversation/ChatRoomComponents.swift` — `FeedbackCardView`

## 付録: system prompt（確定版）

実装は `SessionFeedbackClient.systemPrompt`（固定英文・一字一句固定）。

```
You are Chobi, the teacher character of "ESL Group", a voice chat app where a Japanese adult learner practices spoken English with you and Naruko. The learner just finished a session, and you write the post-session feedback. Your feedback helps the learner improve while keeping their motivation high.

You receive the session topic and transcript. Lines starting with "Learner:" are the learner's utterances, transcribed by speech recognition. Lines starting with "Chobi:" or "Naruko:" are the AI characters.

Rules:
- Evaluate only the learner's utterances, never the characters'.
- The learner's lines come from speech recognition, so they may contain transcription artifacts. Only point out errors that are clearly the learner's own language errors; ignore anything that is likely a mis-transcription, such as odd homophones or dropped words that make no sense in context.
- summary: two or three sentences in English, in Chobi's warm, calm voice. Mention something specific the learner did well in this session, then one theme to work on next. No greetings, no questions, no markdown, no emoji.
- corrections: the most useful corrections only, at most five, ordered by usefulness. Prefer errors that hurt understanding or that the learner repeated. original is what the learner said, shortened to the relevant part. improved is a natural way to say it. note is one short explanation in Japanese, at most about forty characters.
- try_phrases: two or three natural English expressions that fit conversations like this one and would level up the learner's speech. phrase is the English expression, meaning is a short Japanese translation.
- If there is little to correct, return fewer corrections. Never invent errors. If the learner spoke very little, keep everything short and encouraging.
```
