# キャラの記憶の現状実装の調査と改善

## 目的・背景

タイムライン上は過去セッションが表示され続けるため、ユーザーには「Chobi / Naruko と続いているトークルーム」に見える。しかし実際にはセッション（トピック）を開始するたびにキャラは白紙になり、直前のセッションで話した内容も、学習者の名前・属性も一切覚えていない。この非対称を解消し、キャラがセッションをまたいで学習者と過去の会話を覚えている状態を作る。

「発話量を稼ぐ」という第一目的にも寄与する: 学習者のことを覚えているキャラは過去の話題を掘り下げる質問ができ、会話が続きやすい。

## 現状実装の調査結果（Phase 1・完了）

### セッション内の記憶 — 完全にある

- `TurnBasedVoiceSession.history`（`Voice/TurnBasedVoiceSession.swift:77`）がセッション中の全ターンを保持し、毎ターン全履歴を Claude に送信する。
- barge-in 時は読み上げ開始済みの発話までを履歴確定（`commitAssistantTurn(onlyBegun:)`）。セッション内で忘れることはない。

### セッションをまたぐ記憶 — ない

- `ChatRoomStore.startSession`（`Conversation/ChatRoomStore.swift:251`）は常に `initialHistory: []` でセッションを起動し、履歴は `[New topic: X]` 1 件から始まる。
- 唯一の例外はエラー後の再開（`resumeSessionAfterFailure` → `rebuildHistory`）で、これも**現在セッション区間**（最後の sessionDivider 以降）しか復元しない。

### 永続化はあるが、キャラには渡っていない

SwiftData に会話の全記録が残っているのに、会話コンテキストへは一切注入されていない:

| 保存されているもの | 現在の用途 |
| --- | --- |
| `ChatSessionRecord` / `ChatMessageRecord`（speaker 付き全発話） | 起動時の UI タイムライン復元（直近 10 セッション）・管理画面の閲覧のみ |
| `ChatSessionRecord.feedbackJSON`（言語フィードバック） | フィードバックカードの再表示のみ |
| `recentTopicTitles`（直近 20 タイトル） | `TopicSuggestionClient` のトピック重複回避のみ |

### キャラの静的記憶

- system prompt（`Claude/CoachSystemPrompt.swift`）にキャラ設定（Chobi: 猫・コーヒー・ミステリ小説 / Naruko: ラーメン・カラオケ・ソシャゲ）が固定文として存在。プロンプトキャッシュのため一字一句固定（可変情報を埋め込めない）。

### まとめ

「キャラの記憶」は **(a) セッション内 = 完全 / (b) セッション横断 = ゼロ / (c) データ自体は端末に全部ある** という状態。改善は (b) を埋めることに尽きる。

## 対応方針

### 方式比較

| 案 | 内容 | 判断 |
| --- | --- | --- |
| A. 生ログ注入 | 直近 N セッションの発話ログをそのまま initialHistory に積む | ✗ トークンが膨らみ続ける。雑談ログは S/N が低く、キャッシュも効かない |
| **B. ローリング記憶ノート（採用）** | セッション終了時に「前回までの記憶 + 今回の transcript → 更新済み記憶」を生成して 1 本のノートとして保存し、次セッション開始時に注入 | ✓ トークン量が一定。要点だけ残る。生成が 1 回落ちてもデータが壊れない（冪等） |
| B'. フィードバック生成に相乗り | `SessionFeedbackClient`（opus-5）の structured outputs に memory フィールドを追加 | ✗ 言語評価と内容記憶で責務が混ざる。リトライ導線共有でローリング更新が非冪等になる |

### 記憶ノートの設計

- **内容**: 英語の箇条書きノート 1 本（約 400 語以内をプロンプトで指示）。2 部構成を生成プロンプトで指示する:
  - 学習者について知った事実（名前・仕事・家族・好み・予定など、長期に有効なもの）
  - 直近セッションの出来事サマリ（何を話したか。古いものは要約時に自然に淘汰させる）
- **生成**: 新規 `MemoryUpdateClient`（`claude-sonnet-5`・structured outputs `{"memory": string}`・SSE 蓄積は `SessionFeedbackClient` と同型・max_tokens 2000 程度）。入力は「前回までの記憶ノート + 今回の話者ラベル付き transcript」。
- **生成タイミング**: セッション正常終了時（`handleSessionFinished` の `wasEnding` 分岐）。フィードバックと同じく学習者発話 2 未満はスキップ。失敗は best effort（会話は継続、次回終了時の生成でカバーされる）。
- **保存**: SwiftData に単一レコード `CharacterMemoryRecord`（text / updatedAt / 由来 sessionID）。`Persistence/CharacterMemoryStore.swift` を新設し `AppModelContainer` の schema に追加。
- **usage 記録**: `AIUsageEvent` に記憶更新用の kind を追加して `UsageStore` に記録（管理画面の料金集計に載せる）。

### 会話への注入 — `[Memory: ...]` 制御メッセージ

既存の App control messages 枠組み（`[New topic: ...]`）に乗せる:

- `TurnBasedVoiceSession.Configuration` に `memoryNote: String?` を追加。`startInitialTopicIfNeeded` で `[Memory: ...]` と `[New topic: X]` を 1 つの user メッセージに合成して履歴の先頭に積む（記憶が空の初回は Memory 部を省略）。
- `ChatRoomStore.rebuildHistory`（エラー再開）でも同じ合成を行う。
- `CoachSystemPrompt` の「App control messages」節に `[Memory: ...]` の扱いを追記: 過去セッションの記憶として自然に会話に使う。括弧書きを読み上げない・引用しない。記憶の内容を一度に列挙しない。

**プロンプトキャッシュへの影響**: system prompt は固定のまま（追記は一回きりの invalidation で、以後は新しい固定文でキャッシュが効く）。記憶は messages 側の先頭に入り、セッション中は不変なのでプレフィックスを壊さない。`cache_control` は引き続き system の固定ブロックのみに付ける。CLAUDE.md の「システムプロンプトに可変情報を埋め込まない」規約とも整合。

### コスト影響

- 記憶生成: 1 セッションあたり sonnet-5 呼び出し 1 回（入力 数千 tok / 出力 <1k tok）。
- 会話ターン: 毎ターンの入力が記憶ノート分（数百 tok）増える。いずれも軽微。

### スコープ外（今回はやらない）

- `TopicSuggestionClient` への記憶の活用（興味に合ったトピック提案）— 効果はありそうだが別タスクとして切る
- キャラごとに別の記憶を持たせる（Chobi と Naruko で記憶を分ける）— 台本方式では 1 本のノートで十分
- 過去セッションの全文検索・RAG 的な検索

## 影響範囲

| ファイル | 変更 |
| --- | --- |
| `Claude/MemoryUpdateClient.swift` | 新規。記憶ノートのローリング生成 |
| `Persistence/CharacterMemoryStore.swift` | 新規。`CharacterMemoryRecord` の読み書き |
| `Persistence/AppModelContainer.swift` | schema に `CharacterMemoryRecord` 追加 |
| `Conversation/ChatRoomStore.swift` | セッション終了時の記憶更新フック / 起動時の記憶読み込み / `launchSession`・`rebuildHistory` への memoryNote 受け渡し |
| `Voice/TurnBasedVoiceSession.swift` | `Configuration.memoryNote` と開始メッセージ合成 |
| `Claude/CoachSystemPrompt.swift` | App control messages 節に `[Memory: ...]` を追記 |
| `Usage/AIUsage.swift`・`Usage/AIPricing.swift` | 記憶更新の usage kind 追加（必要な範囲で） |
| `Admin/AdminView.swift` ほか | 記憶の閲覧・リセット UI |

## テスト方針

- `MemoryUpdateClientTests`: リクエストボディ（モデル・structured outputs スキーマ・system の cache_control）と `parseResult`（正常 / refusal / malformed）を `SessionFeedbackClientTests` と同じ流儀で検証
- `CharacterMemoryStoreTests`: 保存・上書き・削除（`ChatHistoryStoreTests` と同じく in-memory container）
- `TurnBasedVoiceSession` の開始メッセージ合成: memoryNote あり / なし / 記憶のみ再開時の履歴先頭を検証（既存の CloudPipeline 系テストの流儀に合わせる）
- 手動確認: シミュレータでセッションを 2 回実施し、1 回目で話した内容（例: 名前・趣味）に 2 回目のキャラが言及できることを確認。`xcodebuild` でのビルド確認を完了条件とする

### シミュレータ検証記録（2026-07-26）

`-start-conversation -send-text ...` の自動送信で 2 セッションを通し実行して確認済み:

- セッション 1（名前 + 味噌ラーメン好きを話して goodbye）終了後、記憶ノートが 2 部構成（About the learner / Recent sessions）で生成・保存され、usage が kind `memory` で記録された
- セッション 2 で "Do you remember what food I like?" に対し Naruko が "Miso ramen, right? Every Friday near your office!"、Chobi が "Aw, we do remember, Akira!" と記憶の事実 + 名前に言及
- セッション 2 終了後、ノートに 2 件目のセッションサマリが追記され、学習者の事実は維持（ローリング更新の冪等性）

実機での通し確認（Phase 5）は 2026-07-26 に完了。

## Phase / Step

- [x] Phase 1: 現状実装の調査（本プランの「現状実装の調査結果」に記録）
- [x] Phase 2: 記憶の生成と保存（2026-07-26 実装）
  - `CharacterMemoryRecord` + `CharacterMemoryStore` + schema 追加
  - `MemoryUpdateClient`（sonnet-5・structured outputs・SSE 蓄積・effort medium・max_tokens 2000）
  - セッション正常終了時の更新フック（発話 2 未満スキップ・best effort）+ usage 記録（kind: `memory`）
- [x] Phase 3: 会話への注入（2026-07-26 実装）
  - `Configuration.memoryNote` と `[Memory: ...]` + `[New topic: ...]` の合成（`SessionOpeningMessage.compose`。`rebuildHistory` 含む）
  - `CoachSystemPrompt` に `[Memory: ...]` の扱いを追記（conversation-design.md 付録 A も同期）
- [x] Phase 4: 管理画面での記憶の閲覧・リセット（「記憶」タブ / `MemoryAdminView`）
- [x] Phase 5: 実機での通し確認（2 セッションで記憶の引き継ぎを確認。2026-07-26 完了）
