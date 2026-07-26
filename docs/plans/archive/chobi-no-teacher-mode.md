# Chobi が会話中に先生モードになるのをやめる

## 目的・背景

実会話で Chobi が「Small tip, ...」のような明示的な指導や英語へのメタコメントを挟み、会話が英会話レッスン調（先生モード）になってしまう。本プロダクトの設計では発音・表現のフィードバックは**セッション後**に `SessionFeedbackClient`（Chobi 名義の日本語フィードバック）で行う方針であり、会話中は発話量を稼ぐ「会話相手」に徹してほしい。

原因は会話 system prompt（`CoachSystemPrompt`）の以下の記述:

- Chobi の役割が "the teacher"（A friendly English conversation teacher）
- "Correction policy (Chobi only)" が recast + 「3〜4 ターンに 1 回の明示 tip」を指示している

## 対応方針

会話 system prompt から「教える」役割を撤去し、指導はセッション後フィードバックへ集約する。

1. `EslSpeakingCoach/Claude/CoachSystemPrompt.swift`
   - 冒頭の "conversation partners first and teachers second" を「先生ではない。フィードバックはセッション後にアプリが出す」趣旨に変更
   - Chobi の役割を "the teacher" → "the host"（会話を回す進行役）に変更し、訂正担当の記述を削除
   - "Correction policy (Chobi only)" セクションを "No-teaching policy (both characters)" に置き換え:
     - 会話中は訂正・tip・学習者の英語へのメタコメント（褒めも含む）をしない
     - 意味が取れないときは友達として自然に聞き返す（説明はしない）
     - 正しい言い回しを自分の発話に自然に織り込むのは可（訂正として提示しない）
     - 例外: 学習者から直接言語質問されたときだけ短く答えて会話に戻る
   - 末尾の Remember 行に "no teaching" を追加
2. `docs/specs/conversation-design.md` — キャラ表・ターン進行の訂正ルール・付録 A・受け入れ条件を同内容に更新
3. `EslSpeakingCoach/Conversation/ChatCharacter.swift` — doc コメント（「recast / tip を担当」）を更新

変更しないもの:

- `SessionFeedbackClient` の「You are Chobi, the teacher character」— セッション後の指導は設計どおり Chobi 先生のまま
- TTS スタイル前置文（"like a friendly teacher smiling..."）— 声のトーン指定であり会話内容に影響しない

## 影響範囲

- 会話 system prompt の文言のみ（コードロジック・API パラメータ変更なし）
- プロンプトは一字一句固定のキャッシュ前提。変更後も約 2,000 トークンでキャッシュ最小プレフィックス（1024）を満たす

## テスト方針

- `xcodebuild` でビルドが通ること
- 既存単体テスト（ScriptStreamChunkerTests 等）が通ること
- 実会話での挙動（tip が出ないこと）は実機で確認する（未確認の場合はその旨明示）
