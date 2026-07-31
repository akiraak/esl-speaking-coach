# PracticeMode の役割分離リファクタリング

## 目的・背景

`PracticeMode`（conversation / word / quiz の 1 enum）が現在 5 つの役割を兼ねている。

1. **ヘッダで選ぶ UI の練習モード**（`selectableModes` = 会話 / 単語。UserDefaults `chatRoomPracticeMode`）
2. **セッションの振る舞い一式**（`systemPrompt` / `openingControlKey` / `usesMemoryNote` / `endsOnGoodbye`）
3. **保存レコードの種別タグ**（SwiftData `ChatSessionRecord.modeRawValue`）
4. **カードの種類**（`TopicCard.mode` = 会話カード / 単語カード）
5. **画面文言**（`endSessionButtonTitle` / `idlePrompt` / `topicCardTitle` / `sessionListMarker` / divider・フィードバック見出し）

クイズの単語モード統合（docs/plans/archive/quiz-in-word-mode.md）で「UI モードは word のままセッション種別だけ quiz」という状態が生まれ、不一致を個別対応で吸収している。

- `ChatRoomStore.restoredPracticeMode`: UI モード復元時だけ quiz → word に正規化（セッション復元用の `init(storedValue:)` と二重の復元経路）
- `ChatRoomStore.sessionWordingMode`: 終了ボタン文言のために「セッション中は開始時の種別、それ以外は UI モード」を出し分ける専用機構
- `displayName` / `symbolName` / `idlePrompt` / `topicCardTitle` の `.quiz` ケースは「到達しない」コメント付きの死にケース
- `postTopicCard` の `case .word, .quiz`、`startSession` の `mode != .quiz`、`TopicCardView` の `case .word, .quiz` など switch ごとの個別注釈

**機能は一切変えず**、この軸を「UI の練習モード」と「セッション種別」の 2 型に分離して、現状機能がそのまま素直に書ける構造にする。

## 対応方針

### 新しい型構造

**`PracticeMode`（UI の練習モード）— `conversation` / `word` の 2 ケースに縮める**

- ヘッダのピルで選ぶもの。役割は「セッション外の画面がどちらの顔をしているか」だけ
- rawValue は現行どおり `"conversation"` / `"word"`。UserDefaults `chatRoomPracticeMode` に保存
- `init(storedValue:)` が旧値 `"quiz"` を `.word` へ正規化する（`ChatRoomStore.restoredPracticeMode` を吸収して復元経路を 1 本化。未知・未保存は `.conversation`）
- `selectableModes` は廃止（`allCases` がそのまま選択肢になる）
- カードの種類は UI モードと 1:1（会話カード / 単語カード）なので `TopicCard.mode` はこの型のまま。`.quiz` の死にケースが型ごと消える
- `defaultSessionKind` を持つ（conversation → `.conversation`、word → `.word`。通常のセッション開始の既定値）

**`SessionKind`（セッション種別）— `conversation` / `word` / `quiz` の 3 ケースを新設**

- 新ファイル `EslSpeakingCoach/Conversation/SessionKind.swift`
- rawValue は現行の `"conversation"` / `"word"` / `"quiz"` をそのまま使い、SwiftData `ChatSessionRecord.modeRawValue` に保存する（**保存値・プロパティ名とも不変 = マイグレーション不要**）
- `init(storedValue:)`（未知・未保存は `.conversation`。quiz は quiz のまま —— 既存レコードを化けさせない）
- セッションの振る舞いと文言を持つ: `systemPrompt` / `openingControlKey` / `usesMemoryNote` / `endsOnGoodbye` / `feedbackTopicLabel` / `endSessionButtonTitle` / `sessionListMarker`

### 現メンバーの対応表

| 現 `PracticeMode` のメンバー | 移動先 |
| --- | --- |
| `selectableModes` | 廃止（`PracticeMode.allCases` で代替） |
| `displayName` / `symbolName` / `idlePrompt` | `PracticeMode`（quiz ケース削除） |
| `topicCardTitle` | `PracticeMode`（🎯 のケースはクイズ専用カード廃止以来の死に文言なので削除） |
| `systemPrompt` / `openingControlKey` / `usesMemoryNote` / `endsOnGoodbye` / `feedbackTopicLabel` | `SessionKind` |
| `endSessionButtonTitle` / `sessionListMarker` | `SessionKind` |
| `init(storedValue:)` | 両型に分かれる（UI 側は quiz→word 正規化込み、レコード側は quiz 維持） |

### 利用箇所の置換

- `ChatRoomStore`
  - `practiceMode: PracticeMode`（UI）はそのまま。`restoredPracticeMode` は廃止し `PracticeMode(storedValue:)` に一本化
  - `activeSessionMode` → `activeSessionKind: SessionKind`
  - `startSession(topic:fromCard:mode:)` → `kind: SessionKind? = nil`（既定 `practiceMode.defaultSessionKind`。クイズ導線は `.quiz` を渡す — 現行と同型）
  - `sessionWordingMode`（computed / static 純関数とも）を廃止。終了ボタンと終了確認アラートはセッション中しか操作できないため、`activeSessionKind` を公開してその `endSessionButtonTitle` を直接使う（非セッション中は前セッションの値が残るが、そのときボタンもアラートも出ない）
  - `dividerText(mode:)` / `dividerLabel(mode:)` → `SessionKind` 引数に（quiz の「日付なし・語を出さない」特例はそのまま）
  - `postTopicCard` の switch から `.quiz` ケースが消える（`practiceMode` の型が 2 ケースになるため）
  - `FeedbackCard.mode` → `kind: SessionKind`
- `TurnBasedVoiceSession.Configuration.practiceMode` → `sessionKind: SessionKind`（`[end]` の扱い・system prompt 選択）
- `SessionOpeningMessage.compose(mode:)` → `kind: SessionKind`
- `SessionFeedbackClient.generateFeedback(mode:)` / `makeRequestBody(mode:)` → `kind: SessionKind`
- `ChatHistoryModels`: `ChatSessionRecord.mode`（computed）→ `kind: SessionKind`。stored な `modeRawValue` は名前・値とも変えない
- `ChatHistoryStore`: `SessionSummary.mode` → `kind` / `beginSession(mode:)` → `kind:` / フィルタ（`recentTopicTitles` = conversation、`recentWords` = word、`quizzedTitlesAll` = quiz）を `SessionKind` で
- `SessionListView`: `summary.kind.sessionListMarker`
- `ChatRoomView`: ピルは `PracticeMode.allCases`、終了ボタン・アラートは `store.activeSessionKind` ベースの文言
- `ChatRoomComponents`: `TopicCardView` の switch が 2 分岐に / `FeedbackCardView` の「単語クイズ」特例は `card.kind == .quiz` / `TimelineBottomBar.practiceMode` → `sessionKind: SessionKind`
- `DebugLaunchArguments.practiceModeOverride`: `PracticeMode(storedValue:)` でパース（`quiz` 指定が word になる現行挙動を維持）

### 変えないもの（互換性）

- system prompt の文字列は 1 文字も変えない（プロンプトキャッシュ維持）
- UserDefaults / SwiftData の保存値・キー名は不変。旧端末に残る値もすべて現行と同じ意味に復元される
- UI 文言・API リクエスト・E2E 用起動引数（`-practice-mode` / `-start-from-card` / `-start-quiz`）の挙動は不変

## 影響範囲

- アプリ側 12 ファイル程度: `PracticeMode.swift`（分割）、`SessionKind.swift`（新規）、`ChatRoomStore` / `ChatRoomView` / `ChatRoomComponents` / `ConversationModels` / `TurnBasedVoiceSession` / `SessionFeedbackClient` / `ChatHistoryStore` / `ChatHistoryModels` / `SessionListView` / `DebugLaunchArguments`
- テスト 3 ファイル: `PracticeModeTests`（分割）/ `PracticeModeCardTests` / `ChatHistoryStoreTests`
- ドキュメント: `CLAUDE.md`（練習モードの説明）と `docs/specs/word-practice.md`（モード章）が enum 1 つ前提の記述なので追随させる

## Phase 分割

- **Phase 1: `SessionKind` 新設とセッション種別側の置換**
  - `SessionKind.swift` を追加し、セッション・保存・フィードバック・文言系のメンバーを移す
  - `TurnBasedVoiceSession` / `SessionOpeningMessage` / `SessionFeedbackClient` / `ChatHistoryStore` / `ChatHistoryModels` / `SessionListView` / `ChatRoomStore` のセッション種別系（`activeSessionKind` / `startSession(kind:)` / divider / FeedbackCard）を置換
  - `PracticeMode` は一時的に 3 ケースのまま（UI 系メンバーだけ残る）。ビルド + テスト green
- **Phase 2: `PracticeMode` の 2 ケース化と UI 側の整理**
  - `.quiz` ケース・`selectableModes`・`restoredPracticeMode`・`sessionWordingMode` を削除し、`init(storedValue:)` に quiz→word 正規化を吸収
  - `ChatRoomView` / `ChatRoomComponents` / `DebugLaunchArguments` を追随。死にケースと「到達しない」コメントを一掃。ビルド + テスト green
- **Phase 3: テスト整理とドキュメント更新**
  - `PracticeModeTests` を `PracticeMode`（UI）と `SessionKind` の観点で再編（rawValue 安定性・正規化・プロンプト契約を引き継ぐ）
  - `CLAUDE.md` / `docs/specs/word-practice.md` の該当記述を新構造に更新。プランを archive へ

## テスト方針

- 既存ユニットテストの検証内容は全部引き継ぐ（消してよいのは `sessionWordingMode` の純関数テストのみ = 機構ごと廃止のため）。特に:
  - rawValue の安定性（conversation / word / quiz）と `storedValue` 復元（UI 側 quiz→word、レコード側 quiz 維持、未知→conversation）
  - `endsOnGoodbye` / `usesMemoryNote` / `openingControlKey` / system prompt 選択などプロンプト契約
  - `cardReplacement` / `quizPool` 系の純関数（型置換のみで挙動不変）
- 各 Phase 完了ごとに `xcodebuild` でビルドとユニットテストを green にする
- シミュレータ E2E で確認: 会話⇄単語のピル切替、単語カードからの練習開始、クイズ開始→自動終了、終了ボタン文言（会話 / 単語 / クイズ中）、旧 UserDefaults 値（quiz）からの起動復元
