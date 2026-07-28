# トピックカードの固定候補を「話しかける」にする（最初のターンを学習者から）

## 目的・背景

トピックカードの最後に置いている固定候補「フリートーク」は、選んでも AI（Chobi / Naruko）が
`[New topic: フリートーク]` を受けて口火を切る。つまり「話す内容が決まっていないだけ」で、
開始のしかたは生成トピックと同じ。

このアプリの第一目的は**学習者の発話量を稼ぐこと**なので、
「自分から話しかける」練習（会話を切り出す・話題を自分で立てる）ができる導線を用意する。

- 固定候補を「フリートーク」→「**話しかける**」に置き換える
- これを選んだセッションだけ **AI の開始ターンを出さず、最初のターンを学習者から**にする
- 生成候補は今までどおり **3 件**（カードは「生成 3 件 + 話しかける」の 4 ピル）

2026-07-27 にユーザーとカード構成を確認済み（生成 3 件のまま / フリートークは置き換えて廃止）。

## 現状（コードの事実）

| 項目 | 現状 | 場所 |
| --- | --- | --- |
| 固定候補 | `freeTalkCandidate`（タイトル「フリートーク」/ フック「話したいことをそのまま話そう。」） | `EslSpeakingCoach/Conversation/ChatRoomStore.swift:98` |
| カード表示 | `card.candidates + [freeTalkCandidate]` を縦に並べる | `EslSpeakingCoach/Conversation/ChatRoomComponents.swift:236` |
| 生成件数 | `topicCandidateCount = 3`（初回 3 / 終了後 1 + 持ち越し 2 / 🔄 3） | `ChatRoomStore.swift:105`, `:235`, `:260` |
| セッション開始 | どのトピックでも `configuration.initialTopic = トピック名` を渡す | `ChatRoomStore.swift:394`, `:428` |
| AI の口火 | ready 直後に `[Memory: ...]` + `[New topic: X]` を履歴へ積んで Claude ターンを起こす | `TurnBasedVoiceSession.swift:229`, `:394`, `:506` |
| 開始メッセージの合成 | `SessionOpeningMessage.compose(topic:memoryNote:)`（通常開始とエラー再開の両方で使う） | `ConversationModels.swift:6` |
| エラー再開 | タイムラインから履歴を組み直し、先頭に同じ開始メッセージを置く | `ChatRoomStore.swift:622` |
| 持ち越し | 選択で消費されなかった候補を最大 2 件持ち越す。固定候補・自作トピックでは先頭 2 件 | `ChatRoomStore.swift:331` |

つまり「学習者から始める」経路は現状どこにも無い（`initialTopic == nil` はエラー再開専用）。
仕様書側も `docs/specs/conversation-design.md:150` で「旧 `learner speaks first` は廃止（AI が口火を切る）」と明記してあるので、
**例外モードとして復活させる**形になる（既定は今までどおり AI 開始）。

## 対応方針

### 1. 固定候補の置き換え

- `ChatRoomStore.freeTalkCandidate` → `talkFirstCandidate`
  - タイトル: **話しかける**
  - フック: **自分から話しかけてみよう。**
- 表示位置・並び（候補の後ろ）・持ち越しの扱いは変えない。
  カードは「生成 3 件 + 話しかける」の 4 ピル、🔄・＋ ボタンもそのまま
- 生成件数（`topicCandidateCount = 3`）と持ち越しロジックは**一切変更しない**
  （固定候補を選んだ場合は候補が消費されないので先頭 2 件を持ち越し、生成 1 件。既存のまま）

### 2. 学習者ファーストのセッション開始

このトピックを選んだときだけ、**ready 後に Claude ターンを起こさず listening のまま待つ**。

- `TurnBasedVoiceSession.Configuration` に開始のしかたを持たせる
  ```swift
  enum Opening: Sendable {
      case assistantFirst(topic: String)   // 既定。[New topic: X] を積んで AI が口火を切る
      case learnerFirst                    // 学習者の最初の発話を待つ
      case resume                          // エラー再開（initialHistory を引き継ぐ・開始ターン無し）
  }
  ```
  現行の `initialTopic: String?` を置き換える形にする（`nil` = 再開、という暗黙の区別をやめる）。
  `memoryNote` は従来どおり `Configuration` に持たせる
- `learnerFirst` のとき `startInitialTopicIfNeeded()` は
  **記憶ノートがあれば `[Memory: ...]` だけを履歴に積んで、Claude ターンは起こさない**。
  `state` は `.listening` のまま
  - 学習者が最初に話す（またはテキスト送信する）と `appendUserMessage` が
    直前の user メッセージへ結合するため、Claude には
    `[Memory: ...]\n<学習者の第一声>` という 1 通の user メッセージが届く。
    履歴の形（先頭が user・role が交互）は崩れない
  - `SessionOpeningMessage` に「トピック無し（記憶ノートのみ）」の合成を足す。
    ノートが空なら**何も積まない**（履歴は学習者の第一声から始まる）
- **system prompt（`CoachSystemPrompt`）は変更しない**
  - 開始ターンの作法は `[New topic: ...]` を受けたときの規則なので、
    それが来なければ通常ターン（1〜2 発話 + 最終行に質問 1 つ）として学習者の第一声に反応する。これが欲しい挙動
  - プロンプトを触ればキャッシュを一度作り直すことになるうえ、
    「待て」と書いても最初に呼ばれなければ意味が無い（アプリ側で呼ばなければよい）
  - 実機で挙動が不自然（第一声への反応が薄い / 自分から話題を回収しない）だった場合の代替として、
    `## App control messages` に `[Learner starts]` 制御メッセージの説明を 1 行足す案を残す（Phase 4 で判断）
- `ChatRoomStore.startSession(topic:fromCard:)` は
  トピック名が `talkFirstCandidate.title` と一致したら `Opening.learnerFirst` を渡す
  - 自作トピックに同じ「話しかける」と入力した場合も学習者ファーストになる（実害なし・仕様として許容）
  - 履歴・区切り・`recentTopicTitles` の扱いは従来のフリートークと同じ（`topicGenre` は `nil`）
- `ChatRoomStore.rebuildHistory(topic:)`（エラー再開）も同じ形で組み直す。
  学習者ファーストのセッションでは先頭を `[Memory: ...]`（無ければ学習者の第一発話）にする
  = 通常開始と再開で履歴の形が一致する

### 3. 待ち状態が分かるようにする

AI が黙ったまま listening になるので、開始直後にシステム通知を 1 行だけ出す。

- `.systemNotice`（中央寄せグレー）で「自分から話しかけてみよう」
- 音声モードでは従来どおり listening キューが鳴る（開始の合図は残る）
- 入力中インジケータは出ない（Claude ターンが走っていないため。既存挙動のまま）

## 影響範囲

| ファイル | 変更 |
| --- | --- |
| `EslSpeakingCoach/Conversation/ChatRoomStore.swift` | 固定候補の置き換え / `startSession` の分岐 / `launchSession` の `Opening` 受け渡し / `rebuildHistory` / 開始時のシステム通知 |
| `EslSpeakingCoach/Conversation/ChatRoomComponents.swift` | 固定候補の参照名・コメント（並びは変えない） |
| `EslSpeakingCoach/Conversation/ConversationModels.swift` | `SessionOpeningMessage` にトピック無し（記憶ノートのみ）の合成を追加 |
| `EslSpeakingCoach/Voice/TurnBasedVoiceSession.swift` | `Configuration.initialTopic` → `Opening` / `startInitialTopicIfNeeded` の分岐 / クラスコメントの状態遷移説明 |
| `EslSpeakingCoach/Support/DebugLaunchArguments.swift` | `-start-conversation` のコメント（「フリートーク」→「話しかける」。起動パス確認という目的は変わらない） |
| `EslSpeakingCoachTests/TopicCarryOverTests.swift` | 「フリートーク」を使っているケースを新しい固定候補名に更新 |
| `EslSpeakingCoachTests/SessionOpeningMessageTests.swift` | トピック無し合成のケースを追加 |
| `docs/specs/conversation-design.md` | トピック生成（固定候補の説明）/ セッション進行（開始が 2 経路になる）/ 受け入れ条件 |
| `docs/specs/screen-layout.md` | トピックカードの図と「内容」節（フリートーク → 話しかける） |

`CoachSystemPrompt.swift` と付録 A は**変更しない**（Phase 4 の実機確認で必要と判断したときだけ触る）。
永続化モデル（`ChatSessionRecord` 等）も変更なし。過去セッションに残る「フリートーク」はそのまま表示される。

## Phase

2026-07-27: Phase 1〜3 と Phase 4 の実機確認以外を実装済み。
`Opening` は `Configuration` ではなく `TurnBasedVoiceSession` 直下の enum として定義した
（`Configuration.opening` から参照する形は同じ）。
`SessionOpeningMessage.composeMemoryOnly(memoryNote:)` を追加し、`compose(topic:memoryNote:)` はこれを使う。
`rebuildHistory` は学習者ファーストで履歴が空になりうるため、先頭が assistant になる直列化を落とすガードを入れた。

- [x] **Phase 1: 固定候補の置き換え**
  - `freeTalkCandidate` → `talkFirstCandidate`（タイトル・フック・参照箇所・コメント）
  - この時点では挙動は今までどおり（AI が `[New topic: 話しかける]` で開始する）
  - ビルド + 既存テストが通ること
- [x] **Phase 2: 学習者ファーストの開始経路**
  - `Configuration.Opening` の導入と `startInitialTopicIfNeeded` の分岐
  - `SessionOpeningMessage` のトピック無し合成
  - `ChatRoomStore.startSession` / `launchSession` / `rebuildHistory` の対応
- [x] **Phase 3: 開始直後のシステム通知**
  - 「自分から話しかけてみよう」を 1 行出す
- [ ] **Phase 4: テスト・確認・仕様反映**
  - [x] 単体テスト追加・更新、`xcodebuild test` 全件パス（169 件）
  - [x] シミュレータ E2E（`-start-conversation` で AI が黙って listening → `-send-text` で会話開始。
    Naruko の返しに記憶ノート由来の言及があり `[Memory: ...]` + 第一声が 1 通で届いていることも確認）
  - [x] 実機確認（音声で最初のターンを学習者から / 記憶ノートが効いているか / 応答が不自然でないか）
    - 2026-07-27 確認済み。応答は不自然でなかったため、リスク欄に残していた
      `## App control messages` への `[Learner starts]` 追加は**見送り**（system prompt は変更なし）
  - 仕様書更新（`conversation-design.md` / `screen-layout.md`）、プランを `docs/plans/archive/` へ、`TODO.md` → `DONE.md`

## テスト方針

**単体テスト（純粋関数中心。既存の方針どおり `@MainActor` 依存は避ける）**

- `SessionOpeningMessage`
  - トピックあり + ノートあり / なし（既存）
  - トピック無し + ノートあり → `[Memory: ...]` のみ
  - トピック無し + ノート空 / 空白のみ → `nil`（何も積まない）
- `ChatRoomStore`
  - `carryOverCandidates(from:selectedTitle:)` に固定候補「話しかける」を渡すと先頭 2 件が持ち越される（既存テストの文字列更新）
  - 学習者ファースト判定（トピック名 == 固定候補タイトル）の静的関数
- `TopicSuggestionClient` / `TopicAssignmentSampler` は変更なし（生成件数は 3 件のまま）

**シミュレータ E2E**（マイクは使えないのでテキスト入力で確認）

```bash
./run-simulator.sh   # 既存の起動引数（-send-text 等）は DebugLaunchArguments 参照
```

- カードに「生成 3 件 + 話しかける」の 4 ピルが出る
- 「話しかける」を選ぶ → 区切りが出て、**AI の吹き出しが出ないまま** listening になる
- テキストを送る → Chobi / Naruko が反応し、以降は通常どおりターンが回る
- 会話ログ（管理画面）で Claude への 1 通目が `[Memory: ...]` + 学習者の第一声になっていること

**実機確認**

- 音声で「話しかける」→ 無言で待つ → 自分から話し出して会話が始まる
- 終了 → フィードバック・記憶更新・次のカード（持ち越し 2 件 + 生成 1 件）が従来どおり動く

## リスク・未決

- **AI が黙っている時間の体験**: 待ち受けであることが伝わらないと「壊れた」と感じる。
  Phase 3 のシステム通知で足りるかは実機で判断する（足りなければピルのフックか下端バーの文言で補う）
- **第一声への反応の質**: `[New topic: ...]` が無いぶん、キャラが話題を広げにくい可能性がある。
  不自然なら `## App control messages` に `[Learner starts]` を 1 行足す（プロンプトキャッシュは 1 回だけ作り直しになる）
- **フィードバック生成のトピック名**: 「話しかける」がそのまま渡る（フリートーク時と同じ既知の粗さ）。今回は触らない
- **`recentTopicTitles` に固定候補名が混ざる**: 重複回避リストに「話しかける」が入るだけで実害は無いため、今回は据え置き
