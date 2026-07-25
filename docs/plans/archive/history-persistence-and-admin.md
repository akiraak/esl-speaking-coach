# 会話履歴の永続化 + 管理画面（会話内容・AI 利用料金）

2026-07-25 作成。TODO の「会話履歴の永続化」と「管理画面の作成」をまとめて実装する。

## 目的・背景

- 現状、会話タイムラインは `ChatRoomStore` のメモリ内のみで、アプリ再起動で消える。
  [conversation-design.md](../specs/conversation-design.md) の「会話履歴モデル」で speaker 付き履歴を
  SwiftData 永続化することが決定済み（端末内のみ・iCloud 同期なし）
- あわせて管理画面を作り、(1) 過去セッションの会話内容の閲覧、(2) AI 利用料金の見える化を行う。
  料金の課金ポイントと usage の取り方は [ai-cost-map.md](../specs/ai-cost-map.md) に整理済みで、
  「各 API レスポンスの usage をターンごとに記録するのが正確」という方針に従う

## 対応方針

### Phase 1: SwiftData 基盤 + 会話履歴の永続化

保存対象は「speaker（user / chobi / naruko）付きのメッセージ列をセッション単位で束ねたもの」。
`ConversationMessage`（API 直列化用の role + テキスト）はそのまま残し、永続化モデルは別に立てる。

- 新規 `EslSpeakingCoach/Persistence/ChatHistoryModels.swift`
  - `@Model ChatSessionRecord`: `id: UUID` / `topicTitle` / `startedAt` / `endedAt: Date?` /
    `feedbackJSON: Data?`（生成済み `SessionFeedback` の Codable encode）/ messages（cascade delete）
  - `@Model ChatMessageRecord`: `id: UUID`（= タイムラインの発話 ID）/ `orderIndex: Int` /
    `speaker: String`（"user" / "chobi" / "naruko"）/ `text` / `createdAt` / session（inverse）
- 新規 `EslSpeakingCoach/Persistence/ChatHistoryStore.swift`（@MainActor）
  - `ModelContainer` を注入（テストは in-memory）。セッション作成 / メッセージ追記 /
    ストリーミング中のテキスト更新（発話 ID で引く）/ セッション終了 / フィードバック保存 /
    復元用フェッチ / 直近トピックタイトル取得を提供
- `EslSpeakingCoachApp` で `ModelContainer` を生成し `ChatRoomStore` へ注入
- `ChatRoomStore` の永続化フック
  - `startSession` → セッション作成、`userTurnCommitted` → user メッセージ追記
  - `assistantUtteranceBegan` → AI メッセージ追記、`assistantUtteranceUpdated` → テキスト更新
    （barge-in で読み上げが始まらなかった発話はタイムラインに来ない = 永続化されない。仕様どおり）
  - セッション終了 → `endedAt` 記録。フィードバック生成成功 → JSON 保存
  - `SessionFeedback` を Codable 化（現在 Decodable のみ）
- 起動時復元
  - 直近 10 セッションをタイムラインへ復元（区切り → メッセージ → 保存済みフィードバックカードの順。
    フィードバック未生成の過去セッションにはカードを出さない。全履歴は管理画面で見る）
  - 復元後に新しいトピックカードを投稿（現行の初回投稿と同じ導線）
  - `recentTopicTitles`（重複回避用・直近 20 件）は永続化済みセッションから引く
  - 前回起動がセッション中に落ちていた場合（`endedAt == nil`）は最終メッセージ時刻で閉じる
    （フィードバックなしの過去セッション扱い。再開はしない）
- 保存しないもの: topicCard / systemNotice（一過性）、`[end]` 制御行（そもそもタイムラインに出ない）

### Phase 2: AI 利用量の計測・記録

課金 5 経路（ai-cost-map.md の #1〜#5）すべてで、API レスポンスの usage を取得して記録する。

- 新規 `EslSpeakingCoach/Usage/AIUsage.swift`
  - `AIUsageEvent`: provider（anthropic / openai / gemini）/ model / kind
    （conversationTurn / topicSuggestion / sessionFeedback / speechToText / textToSpeech）/
    inputTokens / outputTokens / cacheReadTokens / cacheWriteTokens / audioSeconds
- 新規 `EslSpeakingCoach/Usage/AIPricing.swift`
  - ai-cost-map.md の単価表をコード化（取得日付きの定数）。実装時に各社の最新料金ページで再確認する
  - `estimatedCostUSD(for:)` で 1 イベントの推定額を計算。**記録時に計算して保存**する
    （単価改定（例: sonnet-5 導入価格の 2026-08-31 終了）が過去の記録を書き換えないように。
    生の usage も保存するので必要なら再計算できる）
- 新規 `EslSpeakingCoach/Persistence/UsageStore.swift` + `@Model APIUsageRecord`
  - timestamp / provider / model / kind / 各トークン数 / audioSeconds / estimatedCostUSD /
    sessionID（会話に紐づかないものは nil）
  - 集計クエリ: 今日 / 今月 / 累計、kind 別・日別のサマリ、セッション別合計
- 取得元の改修
  - `ClaudeSSE`: `message_start`（input_tokens / cache_creation_input_tokens / cache_read_input_tokens）と
    `message_delta`（output_tokens）の usage をパースし `ClaudeStreamEvent` に usage ケースを追加。
    `TurnBasedVoiceSession` が新設の `VoiceSessionEvent.apiUsage` で UI 層へ流す
  - `SessionFeedbackClient` / `TopicSuggestionClient`: usage を戻り値に含め、`ChatRoomStore` が記録
    （フィードバックは SSE 蓄積、トピックは非ストリーミング応答の `usage` フィールド）
  - `OpenAITranscriptionProtocol`: `conversation.item.input_audio_transcription.completed` の
    `usage`（tokens 型 / duration 型の両対応）をパースし、`STTStreamEvent` に usage ケースを追加
  - `SentenceTTSClient`: ストリーム要素を `.pcm(Data)` / `.usage(...)` の enum に変更。
    Gemini は SSE の `usageMetadata`（promptTokenCount / candidatesTokenCount）を採用。
    OpenAI TTS（聞き比べ用）は usage が返らないため受信 PCM バイト数 → 秒数で推定。
    `CloudSentenceSpeaker` に onUsage コールバックを追加してセッションへ中継
  - barge-in でキャンセルしたターンの usage は取れないことがある（推定額は下振れし得る）。
    管理画面に「推定値」であることを明記する

### Phase 3: 管理画面 UI

- 入口: `ChatRoomView` ヘッダの「…」メニューに「管理」を追加 → sheet で表示
- 新規 `EslSpeakingCoach/Admin/` 以下
  - `AdminView`: NavigationStack + セグメント（会話 / 料金）
  - 会話: セッション一覧（日時・トピック・メッセージ数・推定料金）→ 詳細（speaker 別の会話全文 +
    保存済みフィードバック）。スワイプ削除でセッションと紐づく usage 記録も削除
  - 料金: 今日 / 今月 / 累計の推定額カード、種別（STT / 会話 / TTS / トピック / フィードバック）内訳、
    日別一覧。すべて記録済み `estimatedCostUSD` の合算（表示時の再計算はしない）
- 管理画面は既存のトーン（ChatTheme）に合わせるが、ライト固定・標準コンポーネント中心の簡素な作りとする

### Phase 4: 検証・ドキュメント

- `xcodegen generate` → `xcodebuild` ビルド + 単体テスト
- シミュレータ（iPhone 17）でテキスト会話 → アプリ再起動 → 履歴復元・管理画面の表示を確認
- [ai-cost-map.md](../specs/ai-cost-map.md) の「実装状況」欄と単価表を実装に合わせて更新
- 実機（マイク経由の STT usage 記録）は未確認として明示する

## 影響範囲

- 新規: `Persistence/`（モデル + ストア）、`Usage/`（イベント + 料金表）、`Admin/`（画面）
- 変更: `EslSpeakingCoachApp` / `ChatRoomStore` / `ChatRoomView` /
  `ClaudeMessagesClient`（SSE usage）/ `SessionFeedbackClient` / `TopicSuggestionClient` /
  `OpenAITranscriptionProtocol` / `OpenAITranscriptionStream` / `SentenceTTSClient` /
  `GeminiTTSClient` / `OpenAITTSClient` / `CloudSentenceSpeaker` / `TurnBasedVoiceSession` /
  `VoiceSession`（apiUsage イベント追加）
- 会話の挙動（ターン進行・読み上げ・barge-in）自体は変えない。usage は既存ストリームへの
  ケース追加のみで、取りこぼしても会話は継続する（記録は best effort）

## テスト方針

- 単体テスト（既存の XCTest ターゲットに追加）
  - `ClaudeSSE` の usage パース（message_start / message_delta）
  - STT completed イベントの usage パース（tokens 型 / duration 型）
  - Gemini TTS SSE の usageMetadata パース
  - `AIPricing` の推定額計算（代表ケース）
  - `ChatHistoryStore` / `UsageStore` の in-memory ModelContainer での round-trip と集計
  - タイムライン復元（セッション順・メッセージ順・フィードバック有無）
- シミュレータ E2E: 会話 → 終了 → 再起動 → 復元、管理画面の一覧・集計表示
