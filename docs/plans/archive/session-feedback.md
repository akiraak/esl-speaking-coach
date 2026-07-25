# セッション後のフィードバック生成

## 目的・背景

会話中はターン制のため音声レベルの発音指摘をしない方針（CLAUDE.md）。その代わりに、
セッション終了後に会話全文を `claude-opus-5` で評価し、テキストベースのフィードバックカードを
タイムラインへ投稿する（screen-layout.md のセッションの流れ 3–4。カードの内容・レイアウトは
本タスクで定義する、とされている）。

## 内容の定義（本タスクで決める仕様）

- **書き手**: Chobi（先生キャラ）。総評は英語でキャラ性を保ち、訂正・表現の解説は日本語
  （学習効率優先。会話の English-only ルールは会話ターンにのみ適用され、セッション後の
  メタ学習コンテンツには適用しない）
- **構造**（structured outputs で固定）:
  - `summary` — Chobi の総評（英語 2〜3 文。良かった点 + 次の課題 1 つ）
  - `corrections[]` — `original`（学習者の発話の該当部分）/ `improved`（自然な言い方）/
    `note`（日本語の短い解説）。最大 5 件・有用な順。STT の誤認識らしきものは訂正対象にしない
  - `try_phrases[]` — `phrase`（次に使ってみたい英語表現）/ `meaning`（日本語の意味）。2〜3 件
- **スキップ条件**: 学習者の発話（user メッセージ）が 2 未満のセッションは生成しない
  （システムメッセージで省略を通知）
- **投稿順**: セッション終了 → フィードバックカード（生成中表示で即投稿）→ 次のトピックカード。
  生成完了を待たずに次のトピックを選べる。失敗時はカード内にエラー + リトライボタン

## 対応方針

### Phase 1: SessionFeedbackClient（API クライアント）

- `claude-opus-5` / **ストリーミング**（SSE を蓄積して最後に JSON パース。長い生成でも
  接続が切れにくい） / `effort: high` / `max_tokens: 16000` / structured outputs（上記スキーマ）
- SSE パースは既存 `ClaudeSSE` を再利用。`stop_reason` を確認し `refusal` はエラーにする（CLAUDE.md）
- 入力: user メッセージにトピック名 + 話者ラベル付きの会話全文（`Learner:` / `Chobi:` / `Naruko:`）
- 単体テスト: リクエストボディ形状（モデル・effort・max_tokens・サンプリング禁止・スキーマ）、
  結果パース（正常 / refusal / 不正 JSON）

### Phase 2: ChatRoomStore への組み込み

- `TimelineItem.feedbackCard` を追加。セッション正常終了（手動 / goodbye）時に、
  タイムラインの現在セッション区間からトランスクリプトを組み立ててカードを投稿 → 生成タスク開始 →
  直後に次のトピックカードを投稿（生成を待たない）
- user 発話 2 未満はスキップしてシステムメッセージ
- リトライ用にカードへトランスクリプトのスナップショットを保持
- DEBUG: `-send-text` を複数回指定できるようにし、listening のたびに 1 つずつ自動送信
  （シミュレータで複数ターン → goodbye → フィードバックの E2E を回すため）

### Phase 3: FeedbackCardView（UI）

- 白カード + 枠 + 影（トピックカードと同系）。ヘッダ「📝 Session Feedback」+ トピック名
- 総評 → 「直したい表現」（✗ 原文 / ✓ 改善 / 日本語ノート）→ 「使ってみたい表現」（表現 + 意味）
- 生成中は ProgressView + 「Chobi がフィードバックを書いています…」、失敗時はエラー + リトライ

### Phase 4: 確認・ドキュメント

- ビルド / 単体テスト / シミュレータ E2E（2 ターン会話 → goodbye → カード生成まで）
- 仕様書 `docs/specs/session-feedback.md` を新規作成（内容構造・プロンプト・カードレイアウト）し、
  screen-layout.md の未決事項「フィードバックカードの詳細レイアウト」を解消、
  ai-cost-map.md の該当行を「実装済み」に更新

## 影響範囲

- 新規: `EslSpeakingCoach/Claude/SessionFeedbackClient.swift`、`docs/specs/session-feedback.md`
- 変更: `ChatRoomStore` / `ChatRoomView` / `ChatRoomComponents` / `ChatTheme`（✓ 用の緑を追加）/
  `DebugLaunchArguments`（-send-text 複数化）
- テスト: `SessionFeedbackClientTests`（新規）

## テスト方針

- クライアントのリクエスト生成・レスポンスパースは XCTest
- カード投稿フロー・スキップ条件・UI はシミュレータで目視確認（実 API 使用）
